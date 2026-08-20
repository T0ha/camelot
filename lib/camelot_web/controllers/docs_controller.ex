defmodule CamelotWeb.DocsController do
  @moduledoc """
  Serves the public documentation site (`docs.` host). Content is
  compiled from markdown at build time by `Camelot.Docs`; these actions
  just look pages up and render them — no database access.
  """
  use CamelotWeb, :controller

  alias Camelot.Docs

  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, _params) do
    conn
    |> assign(:tree, Docs.tree())
    |> assign(:current, nil)
    |> assign(:page_title, "Documentation")
    |> render(:index)
  end

  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, %{"path" => segments}) do
    render_page(conn, Docs.get_page(Enum.join(segments, "/")))
  end

  @spec render_page(Plug.Conn.t(), {:ok, Docs.Page.t()} | :error) :: Plug.Conn.t()
  defp render_page(conn, {:ok, page}) do
    conn
    |> assign(:tree, Docs.tree())
    |> assign(:current, page.slug)
    |> assign(:page, page)
    |> assign(:page_title, page.title)
    |> render(:show)
  end

  defp render_page(conn, :error) do
    conn
    |> put_status(:not_found)
    |> put_root_layout(html: false)
    |> put_view(CamelotWeb.ErrorHTML)
    |> render(:"404")
  end
end
