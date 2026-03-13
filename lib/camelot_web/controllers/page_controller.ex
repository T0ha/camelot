defmodule CamelotWeb.PageController do
  use CamelotWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
