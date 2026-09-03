defmodule Camelot.Runtime.SecretSync do
  @moduledoc """
  Reconciles `Camelot.Accounts.Credential` rows with
  Swarm secrets. Each `(user_id, kind)` pair has a
  matching secret named
  `camelot_user_<user_id>_<kind>` so runner services
  can mount it at `/run/secrets/<kind>`.

  Swarm secrets are immutable, so "update" means
  delete-then-create under the same name. This GenServer
  owns that dance. For the LocalPort and DockerEngine
  backends it's effectively a no-op — those modes pass
  credentials via env vars.

  The delete half only succeeds while no service
  references the secret, so a rotation can fail for
  reasons that have nothing to do with the new value.
  Every entry point therefore reports that failure
  rather than returning a bare `:ok`: a caller that
  assumes success would hand a runner the *previous*
  value, which for a GitHub App installation token means
  an hour-old, dead credential.
  """
  use GenServer

  alias Camelot.Accounts.Credential
  alias Camelot.Runtime.Runner
  alias Camelot.Runtime.Runner.DockerApi
  alias Camelot.Runtime.Runner.Swarm

  require Ash.Query
  require Logger

  @name __MODULE__
  @bootstrap_retry_ms 5_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: @name)
  end

  @doc """
  Push (or update) the secret for `(user_id, kind)` to
  match the current DB value.
  """
  @spec reconcile(String.t(), atom()) :: :ok
  def reconcile(user_id, kind) do
    GenServer.cast(@name, {:reconcile, user_id, kind})
  end

  @doc """
  Returns the Swarm secret name for a given user and
  kind. Used by the Runner spec builder.

  Docker caps secret names at 64 chars. `camelot_user_<uuid>_` is
  already 49, leaving 15 chars for the kind suffix — `ssh_private_key`
  itself is 15, but adding the underscore separator pushes us to 65.
  Map long kind atoms to short suffixes here; everything outside this
  module (kind atom, mounted file name in `/run/secrets/`, entrypoint
  case) is unaffected.
  """
  @spec secret_name(String.t(), atom()) :: String.t()
  def secret_name(user_id, kind), do: "camelot_user_#{user_id}_#{kind_suffix(kind)}"

  @doc """
  Returns the Swarm secret name for a per-task secret —
  used for `:github_app_token`, which is minted fresh per
  task rather than shared per user/installation, so a
  task's token can be swept independently once the task
  is done (see `Camelot.Runtime.Reconciler`).
  """
  @spec task_secret_name(String.t(), atom()) :: String.t()
  def task_secret_name(task_id, kind), do: "camelot_task_#{task_id}_#{kind_suffix(kind)}"

  @doc """
  Creates (or replaces) an arbitrary Swarm secret. Public,
  synchronous, and stateless — unlike `reconcile/2` it
  isn't tied to a `Credential` row, so callers minting a
  transient token (e.g. a GitHub App installation token)
  can publish it directly.

  Returns the new secret's id, or `{:error, reason}` when the
  rotation could not be completed. Callers must not treat an
  error as harmless: Swarm secrets are immutable, so "replace"
  is delete-then-create, and a rotation that fails leaves the
  *previous* value in place for every service that mounts it.
  """
  @spec put_secret(String.t(), String.t()) ::
          {:ok, String.t()} | {:error, term()}
  def put_secret(name, value), do: upsert_secret(name, value)

  @doc """
  Removes the Swarm secret with the given name. Already-absent
  counts as success; a Docker refusal (most often "secret is in
  use by the following service") comes back as `{:error, _}`.
  """
  @spec delete_secret_by_name(String.t()) :: :ok | {:error, term()}
  def delete_secret_by_name(name), do: delete_secret(name)

  @doc false
  # Classifies a Docker `DELETE /secrets/<id>` response. 404 counts as
  # success — the secret is gone, which is all the caller wanted.
  # Everything else non-2xx is a real failure, most importantly the 400
  # Docker returns while a service still references the secret: that
  # case used to be swallowed, so the create below failed with
  # `AlreadyExists` and the runner mounted the previous, expired token.
  # Public (with `@doc false`) so the rule is unit-testable without a
  # Docker API.
  @spec delete_result(pos_integer(), term()) :: :ok | {:error, term()}
  def delete_result(status, _body) when status in 200..299, do: :ok
  def delete_result(404, _body), do: :ok
  def delete_result(status, body), do: {:error, {:delete_failed, status, body}}

  defp kind_suffix(:ssh_private_key), do: "ssh_pk"
  defp kind_suffix(:github_app_token), do: "gh_token"
  defp kind_suffix(kind), do: Atom.to_string(kind)

  @doc """
  Looks up the current secret id for `(user_id, kind)`.
  """
  @spec lookup_id(String.t(), atom()) :: {:ok, String.t()} | :error
  def lookup_id(user_id, kind) do
    GenServer.call(@name, {:lookup, user_id, kind})
  end

  @doc """
  Looks up the current secret id by its full Swarm name.
  Stateless — bypasses the GenServer, suitable for hot paths
  like runner-spec construction.
  """
  @spec lookup_id_by_name(String.t()) :: {:ok, String.t()} | :error
  def lookup_id_by_name(name), do: fetch_secret_by_name(name)

  # --- GenServer ---

  @impl GenServer
  def init(_opts) do
    if swarm_backend?() do
      {:ok, %{}, 0}
    else
      {:ok, %{}}
    end
  end

  @impl GenServer
  def handle_info(:timeout, state) do
    case DockerApi.ping() do
      :ok ->
        reconcile_all_credentials()
        {:noreply, state}

      _ ->
        Logger.debug("SecretSync: proxy not reachable yet, retrying")
        {:noreply, state, @bootstrap_retry_ms}
    end
  end

  @impl GenServer
  def handle_call({:lookup, user_id, kind}, _from, state) do
    name = secret_name(user_id, kind)

    reply =
      case fetch_secret_by_name(name) do
        {:ok, id} -> {:ok, id}
        _ -> :error
      end

    {:reply, reply, state}
  end

  @impl GenServer
  def handle_cast({:reconcile, user_id, kind}, state) do
    if swarm_backend?() do
      do_reconcile(user_id, kind)
    else
      :ok
    end

    {:noreply, state}
  end

  # --- Internals ---

  defp swarm_backend?, do: Runner.backend() == Swarm

  defp reconcile_all_credentials do
    Credential
    |> Ash.read!()
    |> Enum.each(&do_reconcile(&1.user_id, &1.kind))
  rescue
    e ->
      Logger.warning("SecretSync: bulk reconcile failed: #{Exception.message(e)}")
      :ok
  end

  defp do_reconcile(user_id, kind) do
    cred =
      Credential
      |> Ash.Query.filter(user_id == ^user_id and kind == ^kind)
      |> Ash.Query.load(:value)
      |> Ash.read_first()

    name = secret_name(user_id, kind)

    case cred do
      {:ok, nil} ->
        warn_on_failure(name, delete_secret(name))

      {:ok, %Credential{value: value}} when is_binary(value) ->
        warn_on_failure(name, upsert_secret(name, value))

      {:ok, %Credential{value: nil}} ->
        Logger.warning(
          "SecretSync: credential #{kind} for user #{user_id} has nil value; " <>
            "skipping. Check AshCloak decryption."
        )

      _ ->
        :ok
    end
  rescue
    e ->
      Logger.warning("SecretSync reconcile failed: #{Exception.message(e)}")
      :ok
  end

  # A per-user credential rarely changes value, so a failed rotation
  # here is worth a warning rather than a crash — but never silence.
  # The fatal case is the per-task GitHub App token, whose caller
  # (`Swarm.TaskService`) treats the same error as terminal.
  defp warn_on_failure(_name, :ok), do: :ok
  defp warn_on_failure(_name, {:ok, _id}), do: :ok

  defp warn_on_failure(name, {:error, reason}) do
    Logger.warning(
      "SecretSync: rotating #{name} failed (#{inspect(reason)}); " <>
        "services mounting it keep the previous value"
    )

    :ok
  end

  defp upsert_secret(name, value) do
    with :ok <- delete_secret(name) do
      create_secret(name, value)
    end
  end

  defp fetch_secret_by_name(name) do
    case Req.get(DockerApi.request(), url: "/secrets", params: [filters: ~s({"name":["#{name}"]})]) do
      {:ok, %Req.Response{status: 200, body: [%{"ID" => id} | _]}} -> {:ok, id}
      _ -> :error
    end
  end

  defp create_secret(name, value) do
    payload = %{
      "Name" => name,
      "Data" => Base.encode64(value)
    }

    case Req.post(DockerApi.request(), url: "/secrets/create", json: payload) do
      {:ok, %Req.Response{status: status, body: %{"ID" => id}}}
      when status in 200..299 ->
        {:ok, id}

      {:ok, resp} ->
        {:error, {:create_failed, resp.status, resp.body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp delete_secret(name) do
    case fetch_secret_by_name(name) do
      {:ok, id} -> delete_secret_by_id(id)
      _ -> :ok
    end
  end

  defp delete_secret_by_id(id) do
    case Req.delete(DockerApi.request(), url: "/secrets/#{id}") do
      {:ok, %Req.Response{status: status, body: body}} ->
        delete_result(status, body)

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end
end
