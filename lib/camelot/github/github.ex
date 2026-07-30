defmodule Camelot.Github do
  @moduledoc """
  Domain for GitHub App integration — installation
  records linking Camelot projects to a GitHub App
  installation on github.com.

  App credentials themselves (`app_id`, `private_key`,
  etc.) are deployment config, not a resource here — see
  `Camelot.Github.AppConfig`.
  """
  use Ash.Domain

  resources do
    resource(Camelot.Github.Installation)
  end
end
