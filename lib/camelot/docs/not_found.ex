defmodule Camelot.Docs.NotFound do
  @moduledoc """
  Raised when a published documentation page cannot be found for a slug.
  Carries `plug_status: 404` so Phoenix renders a Not Found response.
  """
  defexception [:message, plug_status: 404]
end
