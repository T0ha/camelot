defmodule Camelot.Agents.ModelApi.Http do
  @moduledoc """
  Live `Camelot.Agents.ModelApi` implementation, over `Req`.

  A single unretried GET with a short receive timeout: the caller is a
  LiveView rendering a dropdown, so a provider that is slow or down
  must cost the page a bounded wait and nothing more — the discovery
  failure degrades to the agent's pinned `available_models`.

  Non-2xx replies come back as `{:error, {:http_error, status, body}}`
  so `Camelot.Telemetry.Reason.classify/1` can bucket them (401/403 →
  `:forbidden`, 429 → `:rate_limited`) without a second mapping here.
  """

  @behaviour Camelot.Agents.ModelApi

  @receive_timeout 3_000

  @impl true
  def list_models(url, headers) do
    [url: url, headers: headers, retry: false, receive_timeout: @receive_timeout]
    |> Req.get()
    |> handle_response()
  end

  @spec handle_response({:ok, Req.Response.t()} | {:error, Exception.t()}) ::
          {:ok, map()} | {:error, term()}
  defp handle_response({:ok, %Req.Response{status: status, body: %{} = body}}) when status in 200..299 do
    {:ok, body}
  end

  # A 2xx that isn't a JSON object is not a listing — the provider
  # answered with something this module can't parse, which is an error
  # rather than an empty catalog.
  defp handle_response({:ok, %Req.Response{status: status, body: body}}) do
    {:error, {:http_error, status, body}}
  end

  defp handle_response({:error, reason}), do: {:error, reason}
end
