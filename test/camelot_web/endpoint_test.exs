defmodule CamelotWeb.EndpointTest do
  use CamelotWeb.ConnCase, async: true

  test "sets PostHog $current_url context for every request", %{conn: conn} do
    conn = get(conn, "/sign-in")

    assert html_response(conn, 200)

    context = PostHog.get_context()

    assert context[:"$pathname"] == "/sign-in"
    assert context[:"$current_url"] =~ "/sign-in"
    assert context[:"$request_method"] == "GET"
  end
end
