defmodule Camelot.Docs do
  @moduledoc """
  Public documentation content, compiled at build time from markdown
  under `docs/<category>/**/*.md` via NimblePublisher.

  Only files with `published: true` front-matter are exposed. Pages are
  rendered to HTML at compile time (no database, no runtime file I/O)
  and served publicly by `CamelotWeb.DocsController`.
  """

  use NimblePublisher,
    build: Camelot.Docs.Page,
    from: "docs/*/**/*.md",
    as: :pages,
    html_converter: Camelot.Docs.Converter

  alias Camelot.Docs.NotFound
  alias Camelot.Docs.Page
  alias Camelot.Docs.Tree

  @published Enum.filter(@pages, & &1.published)

  @doc "All published pages."
  @spec all_pages() :: [Page.t()]
  def all_pages, do: @published

  @doc "Fetch a published page by slug (e.g. `\"runners/cluster-runners\"`)."
  @spec get_page(String.t()) :: {:ok, Page.t()} | :error
  def get_page(slug) do
    case Enum.find(@published, &(&1.slug == slug)) do
      nil -> :error
      page -> {:ok, page}
    end
  end

  @doc "Like `get_page/1` but raises `Camelot.Docs.NotFound` when missing."
  @spec get_page!(String.t()) :: Page.t()
  def get_page!(slug) do
    case get_page(slug) do
      {:ok, page} -> page
      :error -> raise NotFound, "no published doc for slug #{inspect(slug)}"
    end
  end

  @doc "Nested category tree of all published pages, for navigation."
  @spec tree() :: Tree.t()
  def tree, do: Tree.build(@published)
end
