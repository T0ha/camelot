defmodule Camelot.Prompts.Renderer do
  @moduledoc """
  Renders prompt templates by resolving the appropriate
  template (project-specific or global) and interpolating
  variables.
  """

  alias Camelot.Prompts.PromptTemplate

  @placeholder_pattern ~r/\{\{(\w+)\}\}/

  @doc """
  Renders a prompt template for the given slug, with
  project-specific override taking precedence over global.

  Variables is a map of string keys to values, e.g.
  `%{"title" => "Fix bug", "description" => "..."}`.
  """
  @spec render(String.t(), String.t() | nil, map()) ::
          {:ok, String.t()} | {:error, :template_not_found}
  def render(slug, project_id, variables) do
    case resolve_template(slug, project_id) do
      nil -> {:error, :template_not_found}
      template -> {:ok, interpolate(template.body, variables)}
    end
  end

  defp resolve_template(slug, nil) do
    find_template(slug, nil)
  end

  defp resolve_template(slug, project_id) do
    find_template(slug, project_id) || find_template(slug, nil)
  end

  defp find_template(slug, project_id) do
    PromptTemplate
    |> Ash.read!()
    |> Enum.find(fn t ->
      t.slug == slug and t.project_id == project_id
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
