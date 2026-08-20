defmodule Camelot.Docs.Converter do
  @moduledoc """
  NimblePublisher HTML converter for docs pages.

  Renders GFM markdown to HTML with MDEx (mirroring
  `CamelotWeb.Markdown`) and rewrites relative `*.md` cross-links to
  their published slug paths so in-repo links keep working on the site.
  """

  @extensions [
    table: true,
    strikethrough: true,
    autolink: true,
    tasklist: true
  ]

  @doc """
  NimblePublisher callback: convert a source file's markdown `body` to
  HTML. `path` is used to resolve relative cross-links.
  """
  @spec convert(Path.t(), String.t(), map(), keyword()) :: String.t()
  def convert(path, body, _attrs, _opts) do
    html =
      case MDEx.to_html(body, extension: @extensions) do
        {:ok, html} -> html
        {:error, _} -> body
      end

    rewrite_links(html, source_dir(path))
  end

  @doc """
  Rewrite relative `*.md` hrefs in `html` to absolute docs slug paths.

  `dir` is the source file's directory relative to `docs/`, as path
  segments (e.g. `["runners"]`). External, absolute and anchor-only
  links are left untouched.
  """
  @spec rewrite_links(String.t(), [String.t()]) :: String.t()
  def rewrite_links(html, dir) do
    Regex.replace(~r/href="([^"]+)"/, html, fn full, href ->
      case rewrite_href(href, dir) do
        nil -> full
        slug -> ~s(href="#{slug}")
      end
    end)
  end

  @spec rewrite_href(String.t(), [String.t()]) :: String.t() | nil
  defp rewrite_href(href, dir) do
    {rel, anchor} = split_anchor(href)

    if relative_md?(href, rel) do
      base = "/" <> Enum.join(dir, "/")
      Path.rootname(Path.expand(rel, base)) <> anchor
    end
  end

  @spec relative_md?(String.t(), String.t()) :: boolean()
  defp relative_md?(href, rel) do
    not String.starts_with?(href, ["/", "#"]) and
      not Regex.match?(~r{^[a-z][a-z0-9+.-]*://}i, href) and
      String.ends_with?(rel, ".md")
  end

  @spec split_anchor(String.t()) :: {String.t(), String.t()}
  defp split_anchor(href) do
    case String.split(href, "#", parts: 2) do
      [path] -> {path, ""}
      [path, anchor] -> {path, "#" <> anchor}
    end
  end

  @spec source_dir(Path.t()) :: [String.t()]
  defp source_dir(path) do
    path
    |> Path.relative_to("docs")
    |> Path.dirname()
    |> Path.split()
    |> Enum.reject(&(&1 == "."))
  end
end
