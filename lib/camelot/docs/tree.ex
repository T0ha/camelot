defmodule Camelot.Docs.Tree do
  @moduledoc """
  Builds a nested category tree from a flat list of `Camelot.Docs.Page`
  structs, grouping by their `path_segments`. Categories mirror the
  `docs/` directory structure and may nest to arbitrary depth.
  """

  alias Camelot.Docs.Page

  @type t :: %{
          label: String.t() | nil,
          slug: String.t() | nil,
          order: integer(),
          pages: [Page.t()],
          children: [t()]
        }

  @default_order 9999

  @doc """
  Build the root node from `pages`. The root's `pages` are any pages
  living directly under `docs/`; `children` are the category subtrees.
  """
  @spec build([Page.t()]) :: t()
  def build(pages) do
    %{
      label: nil,
      slug: nil,
      order: 0,
      pages: direct_pages(pages, []),
      children: categories(pages, [])
    }
  end

  @spec categories([Page.t()], [String.t()]) :: [t()]
  defp categories(pages, prefix) do
    depth = length(prefix)

    pages
    |> Enum.filter(fn page -> under?(page, prefix) and length(page.path_segments) > depth + 1 end)
    |> Enum.map(fn page -> Enum.at(page.path_segments, depth) end)
    |> Enum.uniq()
    |> Enum.map(fn segment -> category(pages, prefix ++ [segment]) end)
    |> Enum.sort_by(&{&1.order, &1.label})
  end

  @spec category([Page.t()], [String.t()]) :: t()
  defp category(pages, path) do
    %{
      label: humanize(List.last(path)),
      slug: nil,
      order: min_order(pages, path),
      pages: direct_pages(pages, path),
      children: categories(pages, path)
    }
  end

  @spec direct_pages([Page.t()], [String.t()]) :: [Page.t()]
  defp direct_pages(pages, prefix) do
    depth = length(prefix)

    pages
    |> Enum.filter(fn page -> under?(page, prefix) and length(page.path_segments) == depth + 1 end)
    |> Enum.sort_by(&{&1.order, &1.title})
  end

  @spec under?(Page.t(), [String.t()]) :: boolean()
  defp under?(page, prefix), do: Enum.take(page.path_segments, length(prefix)) == prefix

  @spec min_order([Page.t()], [String.t()]) :: integer()
  defp min_order(pages, path) do
    pages
    |> Enum.filter(&under?(&1, path))
    |> Enum.map(& &1.order)
    |> case do
      [] -> @default_order
      orders -> Enum.min(orders)
    end
  end

  @spec humanize(String.t()) :: String.t()
  defp humanize(segment) do
    segment
    |> String.replace(["-", "_"], " ")
    |> String.split(" ", trim: true)
    |> Enum.map_join(" ", &String.capitalize/1)
  end
end
