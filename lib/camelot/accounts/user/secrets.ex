defmodule Camelot.Accounts.User.Secrets do
  @moduledoc """
  Supplies the OAuth secrets the `:github` strategy needs.

  The credentials are the GitHub *App*'s own OAuth
  credentials (`GITHUB_APP_CLIENT_ID` /
  `GITHUB_APP_CLIENT_SECRET`) — the same registration that
  powers the webhook and installation-token paths — so
  self-hosters register one App, not an App plus a separate
  OAuth App.

  `:redirect_uri` returns the *base* of the auth routes;
  `AshAuthentication.Strategy.OAuth2.Plug` appends
  `user/github/callback` to it. Reaching for the endpoint
  from the domain layer mirrors
  `Camelot.Accounts.User.Senders.SendMagicLink`.
  """
  use AshAuthentication.Secret

  alias Camelot.Accounts.User
  alias Camelot.Github.AppConfig

  @impl AshAuthentication.Secret
  @spec secret_for([atom()], Ash.Resource.t(), keyword(), map()) ::
          {:ok, String.t()} | :error
  def secret_for([:authentication, :strategies, :github, :client_id], User, _opts, _context),
    do: from_app_config(:client_id)

  def secret_for([:authentication, :strategies, :github, :client_secret], User, _opts, _context),
    do: from_app_config(:client_secret)

  def secret_for([:authentication, :strategies, :github, :redirect_uri], User, _opts, _context),
    do: {:ok, CamelotWeb.Endpoint.url() <> "/auth"}

  def secret_for(_path, _resource, _opts, _context), do: :error

  defp from_app_config(key) do
    case AppConfig.fetch() do
      {:ok, config} -> {:ok, Map.fetch!(config, key)}
      :not_configured -> :error
    end
  end
end
