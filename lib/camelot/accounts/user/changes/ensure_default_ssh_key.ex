defmodule Camelot.Accounts.User.Changes.EnsureDefaultSshKey do
  @moduledoc """
  Idempotently provisions a server-generated Ed25519 SSH keypair for a
  user.

  Wired into `User.:create_user` as an `after_action` so every new
  user — admin-created or first-time magic-link sign-in — leaves the
  action with `kind: :ssh_private_key, name: "default"` Credential and
  a Swarm secret already on its way to the cluster.

  Also exposed as `ensure_default_for/1` so legacy users without a key
  get backfilled on their next visit to `/profile`.

  Keygen failure is non-fatal: the user is created either way and the
  fallback path in the UI lets them retry.
  """
  use Ash.Resource.Change

  alias Camelot.Accounts.Credential
  alias Camelot.Accounts.SshKeygen
  alias Camelot.Runtime.SecretSync

  require Ash.Query
  require Logger

  @kind :ssh_private_key
  @name "default"

  @impl Ash.Resource.Change
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, user ->
      _ = safely_ensure(user.id)
      {:ok, user}
    end)
  end

  @doc """
  Guarantee the user has a server-generated default SSH credential.

  No-op if one already exists. Returns `{:ok, credential}` on success
  or `{:error, reason}` if generation/persistence failed.
  """
  @spec ensure_default_for(String.t()) ::
          {:ok, Credential.t()} | {:error, term()}
  def ensure_default_for(user_id) when is_binary(user_id) do
    case fetch_default(user_id) do
      {:ok, %Credential{} = cred} ->
        {:ok, cred}

      :missing ->
        create_default(user_id)
    end
  end

  defp safely_ensure(user_id) do
    ensure_default_for(user_id)
  rescue
    error ->
      Logger.warning(
        "EnsureDefaultSshKey: keygen failed for user #{user_id} — " <>
          Exception.format(:error, error, __STACKTRACE__)
      )

      {:error, error}
  end

  defp fetch_default(user_id) do
    Credential
    |> Ash.Query.filter(user_id == ^user_id and kind == ^@kind and name == ^@name)
    |> Ash.Query.limit(1)
    |> Ash.read!()
    |> case do
      [cred | _] -> {:ok, cred}
      [] -> :missing
    end
  end

  defp create_default(user_id) do
    %{
      private_key: priv,
      public_key: pub,
      fingerprint: fp,
      algorithm: algo
    } = SshKeygen.generate(comment: "camelot@#{user_id}")

    metadata = %{
      "public_key" => String.trim(pub),
      "fingerprint" => fp,
      "algorithm" => algo,
      "source" => "server_generated",
      "generated_at" => DateTime.to_iso8601(DateTime.utc_now())
    }

    case Ash.create(Credential, %{
           user_id: user_id,
           kind: @kind,
           name: @name,
           value: priv,
           metadata: metadata
         }) do
      {:ok, cred} ->
        SecretSync.reconcile(user_id, @kind)
        {:ok, cred}

      {:error, error} ->
        Logger.warning(
          "EnsureDefaultSshKey: failed to persist credential for user " <>
            "#{user_id} — #{inspect(error)}"
        )

        {:error, error}
    end
  end
end
