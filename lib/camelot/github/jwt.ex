defmodule Camelot.Github.Jwt do
  @moduledoc """
  Mints the short-lived RS256 JWT GitHub requires to
  authenticate as the App itself (as opposed to one of
  its installations) — used only to mint installation
  access tokens via
  `POST /app/installations/:id/access_tokens`.
  """

  alias Camelot.Github.AppConfig

  # GitHub rejects `iat` in the future, so back-date it a
  # little to absorb clock skew between us and GitHub.
  @clock_skew_s 60
  @ttl_s 600

  @doc """
  Builds and RS256-signs an App JWT from the configured
  `app_id`/`private_key`. Returns `:not_configured` when
  the GitHub App integration isn't set up.
  """
  @spec signed_jwt() :: {:ok, String.t()} | {:error, term()} | :not_configured
  def signed_jwt do
    case AppConfig.fetch() do
      {:ok, %{app_id: app_id, private_key: pem}} -> sign(app_id, pem)
      :not_configured -> :not_configured
    end
  end

  defp sign(app_id, pem) do
    now = System.system_time(:second)

    claims = %{
      "iat" => now - @clock_skew_s,
      "exp" => now + @ttl_s,
      "iss" => app_id
    }

    signer = Joken.Signer.create("RS256", %{"pem" => pem})

    case Joken.generate_and_sign(%{}, claims, signer) do
      {:ok, token, _claims} -> {:ok, token}
      {:error, reason} -> {:error, reason}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end
end
