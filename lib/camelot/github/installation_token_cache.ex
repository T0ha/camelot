defmodule Camelot.Github.InstallationTokenCache do
  @moduledoc """
  Caches per-installation GitHub App access tokens in an
  ETS table, minting fresh ones via
  `POST /app/installations/:id/access_tokens` when the
  cached token has less than 5 minutes left (or none is
  cached).

  Short-circuits without a network call when the App
  isn't configured (`:not_configured`) or the
  installation is suspended (`:suspended`).
  """
  use GenServer

  alias Camelot.Github.AppConfig
  alias Camelot.Github.Installation
  alias Camelot.Github.Jwt

  require Ash.Query
  require Logger

  @name __MODULE__
  @table __MODULE__
  @base_url "https://api.github.com"
  # GitHub installation tokens last ~1h; refresh once fewer than
  # this many seconds remain so a slow caller never races expiry.
  @refresh_margin_s 300

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: @name)
  end

  @doc """
  Returns a valid installation access token, from cache
  or freshly minted.
  """
  @spec fetch(integer()) ::
          {:ok, String.t()}
          | {:error, :not_configured | :suspended | :not_found | term()}
  def fetch(installation_id) do
    case cached(installation_id) do
      {:ok, token} -> {:ok, token}
      :miss -> GenServer.call(@name, {:mint, installation_id}, 15_000)
    end
  end

  @impl GenServer
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{}}
  end

  @impl GenServer
  def handle_call({:mint, installation_id}, _from, state) do
    # Re-check the cache inside the GenServer in case a concurrent
    # caller already minted while this call waited in the mailbox.
    reply =
      case cached(installation_id) do
        {:ok, token} -> {:ok, token}
        :miss -> mint(installation_id)
      end

    {:reply, reply, state}
  end

  defp cached(installation_id) do
    case :ets.lookup(@table, installation_id) do
      [{^installation_id, token, expires_at}] ->
        if DateTime.diff(expires_at, DateTime.utc_now()) > @refresh_margin_s do
          {:ok, token}
        else
          :miss
        end

      [] ->
        :miss
    end
  end

  defp mint(installation_id) do
    with true <- AppConfig.configured?(),
         :ok <- ensure_not_suspended(installation_id),
         {:ok, jwt} <- Jwt.signed_jwt(),
         {:ok, token, expires_at} <- request_token(installation_id, jwt) do
      :ets.insert(@table, {installation_id, token, expires_at})
      {:ok, token}
    else
      false -> {:error, :not_configured}
      :not_configured -> {:error, :not_configured}
      {:error, _} = err -> err
    end
  end

  defp ensure_not_suspended(installation_id) do
    Installation
    |> Ash.Query.filter(installation_id == ^installation_id)
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, %Installation{suspended_at: nil}} -> :ok
      {:ok, %Installation{}} -> {:error, :suspended}
      {:ok, nil} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp request_token(installation_id, jwt) do
    url = @base_url <> "/app/installations/#{installation_id}/access_tokens"

    opts = [
      method: :post,
      url: url,
      headers: [
        {"authorization", "Bearer #{jwt}"},
        {"accept", "application/vnd.github+json"}
      ]
    ]

    case Req.request(opts) do
      {:ok, %Req.Response{status: 201, body: %{"token" => token, "expires_at" => iso}}} ->
        {:ok, token, parse_expiry(iso)}

      {:ok, %Req.Response{status: status, body: body}} ->
        Logger.warning("GitHub installation token mint #{status}: #{inspect(body)}")
        {:error, {:http_error, status, body}}

      {:error, reason} ->
        Logger.error("GitHub installation token mint failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp parse_expiry(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _offset} -> dt
      _ -> DateTime.add(DateTime.utc_now(), 3_600, :second)
    end
  end
end
