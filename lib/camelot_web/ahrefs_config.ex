defmodule CamelotWeb.AhrefsConfig do
  @moduledoc """
  Exposes the Ahrefs Web Analytics site key to the page layouts.

  Ahrefs is a production-only concern: both the app and the docs site
  render its snippet only when a site key is configured via
  `AHREFS_ANALYTICS_KEY` at runtime (see `config/runtime.exs`). Test and
  dev deployments run the same `MIX_ENV=prod` release, so the env var —
  not `config_env/0` — is what keeps their traffic out of the report.
  """

  @doc """
  The configured Ahrefs site key, or `nil` when analytics is disabled.
  """
  @spec key() :: String.t() | nil
  def key, do: Application.get_env(:camelot, :ahrefs, [])[:key]
end
