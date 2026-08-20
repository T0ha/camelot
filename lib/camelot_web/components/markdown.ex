defmodule CamelotWeb.Markdown do
  @moduledoc """
  Shared GFM-to-HTML rendering for user- and agent-authored
  markdown (task descriptions, plans).
  """

  # GFM extensions so plan/description markdown renders tables,
  # strikethrough, autolinks and task lists instead of raw text.
  @extensions [
    table: true,
    strikethrough: true,
    autolink: true,
    tasklist: true
  ]

  @doc """
  Render markdown to safe HTML. Falls back to the raw text on
  a parse error and to an empty string for non-binary input.
  """
  @spec render(String.t() | nil) :: Phoenix.HTML.safe() | String.t()
  def render(text) when is_binary(text) do
    case MDEx.to_html(text, extension: @extensions) do
      {:ok, html} -> Phoenix.HTML.raw(html)
      {:error, _} -> text
    end
  end

  def render(_), do: ""
end
