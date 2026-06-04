defmodule Camelot.Runtime.SecretSync do
  @moduledoc """
  Reconciles `Camelot.Accounts.Credential` rows with
  Swarm secrets. Each `(user_id, kind)` pair has a
  matching secret named
  `camelot_user_<user_id>_<kind>` so runner services
  can mount it at `/run/secrets/<kind>`.

  Swarm secrets are immutable, so "update" means
  create-new / rotate-service-references / delete-old.
  This GenServer owns that dance. For the LocalPort and
  DockerEngine backends it's effectively a no-op —
  those modes pass credentials via env vars.
  """
  use GenServer

  alias Camelot.Accounts.Credential
  alias Camelot.Runtime.Runner
  alias Camelot.Runtime.Runner.DockerApi
  alias Camelot.Runtime.Runner.Swarm

  require Ash.Query
  require Logger

  @name __MODULE__

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
  """
  @spec secret_name(String.t(), atom()) :: String.t()
  def secret_name(user_id, kind), do: "camelot_user_#{user_id}_#{kind}"

  @doc """
  Looks up the current secret id for `(user_id, kind)`.
  """
  @spec lookup_id(String.t(), atom()) :: {:ok, String.t()} | :error
  def lookup_id(user_id, kind) do
    GenServer.call(@name, {:lookup, user_id, kind})
  end

  # --- GenServer ---

  @impl GenServer
  def init(_opts) do
    {:ok, %{}}
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

  defp do_reconcile(user_id, kind) do
    cred =
      Credential
      |> Ash.Query.filter(user_id == ^user_id and kind == ^kind)
      |> Ash.read_first()

    case cred do
      {:ok, nil} -> delete_secret(secret_name(user_id, kind))
      {:ok, %Credential{value: value}} -> upsert_secret(secret_name(user_id, kind), value)
      _ -> :ok
    end
  rescue
    e ->
      Logger.warning("SecretSync reconcile failed: #{Exception.message(e)}")
      :ok
  end

  defp upsert_secret(name, value) do
    case fetch_secret_by_name(name) do
      {:ok, old_id} ->
        delete_secret_by_id(old_id)
        create_secret(name, value)

      _ ->
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
      {:ok, %Req.Response{status: status}} when status in 200..299 ->
        :ok

      {:ok, resp} ->
        Logger.warning("SecretSync create #{name} failed: #{inspect(resp.body)}")
        :ok

      {:error, reason} ->
        Logger.warning("SecretSync create #{name} failed: #{inspect(reason)}")
        :ok
    end
  end

  defp delete_secret(name) do
    case fetch_secret_by_name(name) do
      {:ok, id} -> delete_secret_by_id(id)
      _ -> :ok
    end
  end

  defp delete_secret_by_id(id) do
    Req.delete(DockerApi.request(), url: "/secrets/#{id}")
    :ok
  rescue
    _ -> :ok
  end
end
