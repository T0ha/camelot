defmodule CamelotWeb.PageControllerTest do
  use CamelotWeb.ConnCase

  test "GET / redirects to sign-in when not authenticated",
       %{conn: conn} do
    conn = get(conn, ~p"/")
    assert redirected_to(conn) == "/sign-in"
  end

  test "GET /sign-in renders the sign-in page",
       %{conn: conn} do
    conn = get(conn, ~p"/sign-in")
    assert html_response(conn, 200)
  end
end
