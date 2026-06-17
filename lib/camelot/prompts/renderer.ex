defmodule Camelot.Prompts.Renderer do
  @moduledoc """
  Renders prompt templates by resolving the appropriate
  template (project-specific or global) and interpolating
  variables.
  """

  alias Camelot.Prompts.PromptTemplate

  @placeholder_pattern ~r/\{\{(\w+)\}\}/

  @doc """
  Renders a prompt template for the given slug. Resolution order:
  project-specific → user-global → system-global. The first match wins.

  Variables is a map of string keys to values, e.g.
  `%{"title" => "Fix bug", "description" => "..."}`.
  """
  @spec render(String.t(), String.t() | nil, String.t() | nil, map()) ::
          {:ok, String.t()} | {:error, :template_not_found}
  def render(slug, project_id, user_id, variables) do
    case resolve_template(slug, project_id, user_id) do
      nil -> {:error, :template_not_found}
      template -> {:ok, interpolate(template.body, variables)}
    end
  end

  defp resolve_template(slug, project_id, user_id) do
    templates = Ash.read!(PromptTemplate)

    find_in(templates, slug, project_id, nil) ||
      find_in(templates, slug, nil, user_id) ||
      find_in(templates, slug, nil, nil)
  end

  defp find_in(templates, slug, project_id, user_id) do
    Enum.find(templates, fn t ->
      t.slug == slug and t.project_id == project_id and t.user_id == user_id
    end)
  end

  defp interpolate(body, variables) do
    body
    |> String.replace(@placeholder_pattern, fn match ->
      case Regex.run(@placeholder_pattern, match) do
        [_, key] -> Map.get(variables, key, "")
        _ -> match
      end
    end)
    |> strip_blank_lines()
  end

  defp strip_blank_lines(text) do
    text
    |> String.split("\n")
    |> Enum.reject(&(String.trim(&1) == ""))
    |> Enum.join("\n")
  end
end
