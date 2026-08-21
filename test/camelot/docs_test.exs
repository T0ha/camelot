defmodule Camelot.DocsTest do
  use ExUnit.Case, async: true

  alias Camelot.Docs
  alias Camelot.Docs.Converter
  alias Camelot.Docs.Page
  alias Camelot.Docs.Tree

  describe "all_pages/0 and get_page/1" do
    test "exposes only published pages in category folders" do
      slugs = Enum.map(Docs.all_pages(), & &1.slug)

      assert "self-hosting/cluster-runners" in slugs
      assert "self-hosting/github-app" in slugs

      # Internal docs live flat under docs/ (not in a category folder), so
      # they are never globbed or published.
      refute Enum.any?(slugs, &String.contains?(&1, "planning-output-contract"))
      refute Enum.any?(slugs, &String.contains?(&1, "session-adoption"))
    end

    test "get_page/1 returns the page or :error" do
      assert {:ok, %Page{title: title, body: body}} =
               Docs.get_page("self-hosting/cluster-runners")

      assert is_binary(title) and title != ""
      # body is rendered HTML
      assert body =~ "<h1>"

      assert :error = Docs.get_page("does/not-exist")
    end

    test "get_page!/1 raises Camelot.Docs.NotFound for unknown slug" do
      assert_raise Docs.NotFound, fn -> Docs.get_page!("nope") end
    end
  end

  describe "Tree.build/1" do
    setup do
      pages = [
        page(["runners", "cluster"], "Cluster", 1),
        page(["runners", "local", "deep"], "Deep", 2),
        page(["integrations", "gh"], "GH", 5)
      ]

      {:ok, tree: Tree.build(pages)}
    end

    test "orders categories by their minimum page order", %{tree: tree} do
      assert Enum.map(tree.children, & &1.label) == ["Runners", "Integrations"]
    end

    test "nests sub-categories to arbitrary depth", %{tree: tree} do
      runners = Enum.find(tree.children, &(&1.label == "Runners"))

      assert Enum.map(runners.pages, & &1.slug) == ["runners/cluster"]
      assert [%{label: "Local"} = local] = runners.children
      assert Enum.map(local.pages, & &1.slug) == ["runners/local/deep"]
      assert local.children == []
    end
  end

  describe "Converter.rewrite_links/2" do
    test "rewrites a sibling .md link to an absolute slug path" do
      html = ~s(<a href="cluster-runners.md">x</a>)

      assert Converter.rewrite_links(html, ["runners"]) ==
               ~s(<a href="/runners/cluster-runners">x</a>)
    end

    test "resolves parent-relative links and preserves anchors" do
      html = ~s(<a href="../integrations/github-app.md#setup">x</a>)

      assert Converter.rewrite_links(html, ["runners"]) ==
               ~s(<a href="/integrations/github-app#setup">x</a>)
    end

    test "leaves external, absolute and anchor links untouched" do
      html =
        ~s(<a href="https://x.com/a.md">e</a>) <>
          ~s(<a href="/foo">a</a><a href="#frag">f</a>)

      assert Converter.rewrite_links(html, ["runners"]) == html
    end
  end

  defp page(segments, title, order) do
    %Page{
      slug: Enum.join(segments, "/"),
      path_segments: segments,
      title: title,
      description: nil,
      body: "",
      order: order,
      published: true
    }
  end
end
