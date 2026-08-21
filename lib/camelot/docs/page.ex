defmodule Camelot.Docs.Page do
  @moduledoc """
  A single documentation page, built at compile time by `Camelot.Docs`
  from a markdown file under `docs/<category>/`.

  The `body` is already-rendered HTML; `slug` and `path_segments` are
  derived from the file's path relative to `docs/` (without extension).
  """

  @enforce_keys [:slug, :path_segments, :title, :body, :order, :published]
  defstruct [:slug, :path_segments, :title, :description, :body, :order, :published]

  @type t :: %__MODULE__{
          slug: String.t(),
          path_segments: [String.t()],
          title: String.t(),
          description: String.t() | nil,
          body: String.t(),
          order: integer(),
          published: boolean()
        }

  @default_order 9999

  @doc """
  Build a page from its source `path`, front-matter `attrs` and the
  already-converted HTML `body`. Called by NimblePublisher for every
  globbed file.
  """
  @spec build(Path.t(), map(), String.t()) :: t()
  def build(path, attrs, body) do
    segments = path_segments(path)

    %__MODULE__{
      slug: Enum.join(segments, "/"),
      path_segments: segments,
      title: attrs[:title] || title_from_html(body) || Enum.join(segments, "/"),
      description: attrs[:description],
      order: attrs[:order] || @default_order,
      published: attrs[:published] == true,
      body: body
    }
  end

  @spec path_segments(Path.t()) :: [String.t()]
  defp path_segments(path) do
    path
    |> Path.relative_to("docs")
    |> Path.rootname()
    |> Path.split()
  end

  @spec title_from_html(String.t()) :: String.t() | nil
  defp title_from_html(html) do
    case Regex.run(~r/<h1[^>]*>(.*?)<\/h1>/s, html) do
      [_, inner] -> inner |> strip_tags() |> String.trim()
      _ -> nil
    end
  end

  @spec strip_tags(String.t()) :: String.t()
  defp strip_tags(html), do: Regex.replace(~r/<[^>]+>/, html, "")
end
