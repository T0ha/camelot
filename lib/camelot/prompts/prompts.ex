defmodule Camelot.Prompts do
  @moduledoc """
  Domain for prompt template management.
  """
  use Ash.Domain

  resources do
    resource(Camelot.Prompts.PromptTemplate)
  end
end
