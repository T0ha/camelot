defmodule Camelot.Accounts.MagicLink do
  @moduledoc """
  Runtime switch for email magic-link sign-in.

  The `magic_link` strategy is declared statically on
  `Camelot.Accounts.User`, so it can't be removed by configuration.
  Instead `:magic_link_enabled` (env var `MAGIC_LINK_ENABLED`,
  default `true`) is enforced at runtime by
  `CamelotWeb.Plugs.MagicLinkGate`, the link sender and the sign-in
  page.
  """

  @doc "Whether magic-link sign-in is currently enabled."
  @spec enabled?() :: boolean()
  def enabled?, do: Application.get_env(:camelot, :magic_link_enabled, true)
end
