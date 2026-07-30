defmodule Camelot.Github.AppConfig do
  @moduledoc """
  Reads the GitHub App's static credentials from
  `Application.get_env(:camelot, :github_app)`
  (populated in `config/runtime.exs` from six
  `GITHUB_APP_*` env vars).

  These are per-deployment infrastructure secrets set
  once by whoever registers the App on github.com — like
  `ENCRYPTION_KEY` or `SECRET_KEY_BASE`, they live in
  deployment config, not an editable database row. The
  integration is opt-in: every field is optional, and
  `fetch/0` returns `:not_configured` unless all of them
  are present.
  """

  @type t :: %{
          app_id: String.t(),
          slug: String.t(),
          client_id: String.t(),
          client_secret: String.t(),
          private_key: String.t(),
          webhook_secret: String.t()
        }

  @required_keys [:app_id, :slug, :client_id, :client_secret, :private_key, :webhook_secret]

  @doc """
  Fetches the configured GitHub App credentials. The
  `private_key` field is base64-decoded from
  `GITHUB_APP_PRIVATE_KEY_B64` back into PEM text.

  Returns `:not_configured` when any required field is
  missing/blank, or when the private key isn't valid
  base64.
  """
  @spec fetch() :: {:ok, t()} | :not_configured
  def fetch do
    raw = Application.get_env(:camelot, :github_app, [])

    with true <- all_present?(raw),
         {:ok, decoded_key} <- decode_private_key(raw[:private_key]) do
      {:ok,
       %{
         app_id: raw[:app_id],
         slug: raw[:slug],
         client_id: raw[:client_id],
         client_secret: raw[:client_secret],
         private_key: decoded_key,
         webhook_secret: raw[:webhook_secret]
       }}
    else
      _ -> :not_configured
    end
  end

  @doc """
  Whether the GitHub App integration is configured for
  this deployment.
  """
  @spec configured?() :: boolean()
  def configured? do
    match?({:ok, _}, fetch())
  end

  defp all_present?(raw) do
    Enum.all?(@required_keys, fn key ->
      case raw[key] do
        value when is_binary(value) -> String.trim(value) != ""
        _ -> false
      end
    end)
  end

  defp decode_private_key(b64) do
    case Base.decode64(b64) do
      {:ok, pem} -> {:ok, pem}
      :error -> :error
    end
  end
end
