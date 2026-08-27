defmodule CamelotWeb.DocsHTML do
  @moduledoc """
  Templates and navigation components for the public docs site.
  """
  use CamelotWeb, :html

  embed_templates "docs_html/*"

  @doc """
  Page shell shared by the index and article views: a category-tree
  sidebar plus the main content slot (rendered with `.prose` styling).
  """
  attr :tree, :map, required: true
  attr :current, :string, default: nil
  slot :inner_block, required: true

  def shell(assigns) do
    ~H"""
    <div class="min-h-screen flex flex-col md:flex-row bg-base-100 text-base-content">
      <aside class="md:w-72 shrink-0 border-b border-base-300 md:border-b-0 md:border-r bg-base-200">
        <div class="p-4">
          <a href="/" class="text-xl font-brand text-primary">🏰 Camelot AI Docs</a>
        </div>
        <.nav_tree node={@tree} current={@current} />
      </aside>

      <main class="flex-1 min-w-0 px-6 py-8">
        <article class="prose max-w-3xl mx-auto">
          {render_slot(@inner_block)}
        </article>
      </main>
    </div>
    """
  end

  @doc """
  Recursively render a `Camelot.Docs.tree/0` node as a nested daisyUI
  menu: pages as links, sub-categories as collapsible groups.
  """
  attr :node, :map, required: true
  attr :current, :string, default: nil

  def nav_tree(assigns) do
    ~H"""
    <ul class="menu w-full">
      <li :for={page <- @node.pages}>
        <a href={"/" <> page.slug} class={page.slug == @current && "menu-active font-semibold"}>
          {page.title}
        </a>
      </li>
      <li :for={child <- @node.children}>
        <details open>
          <summary class="font-semibold">{child.label}</summary>
          <.nav_tree node={child} current={@current} />
        </details>
      </li>
    </ul>
    """
  end
end
