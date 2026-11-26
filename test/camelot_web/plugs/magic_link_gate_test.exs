defmodule CamelotWeb.Plugs.MagicLinkGateTest do
  use CamelotWeb.ConnCase, async: false

  alias CamelotWeb.Plugs.MagicLinkGate

  setup do
    original = Application.get_env(:camelot, :magic_link_enabled)

    on_exit(fn ->
      Application.put_env(:camelot, :magic_link_enabled, original)
    end)

    :ok
  end

  defp conn_for(method, path) do
    method
    |> build_conn(path)
    |> Plug.Conn.fetch_query_params()
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Phoenix.Controller.fetch_flash()
  end

  @paths [
    {:post, "/auth/user/magic_link/request"},
    {:get, "/auth/user/magic_link"},
    {:get, "/magic_link/some-token"}
  ]

  describe "when magic link is enabled" do
    setup do
      Application.put_env(:camelot, :magic_link_enabled, true)
      :ok
    end

    for {method, path} <- @paths do
      test "lets #{method} #{path} through" do
        conn = MagicLinkGate.call(conn_for(unquote(method), unquote(path)), [])
        refute conn.halted
      end
    end
  end

  describe "when magic link is disabled" do
    setup do
      Application.put_env(:camelot, :magic_link_enabled, false)
      :ok
    end

    for {method, path} <- @paths do
      test "halts #{method} #{path} with a flash and redirect" do
        conn = MagicLinkGate.call(conn_for(unquote(method), unquote(path)), [])

        assert conn.halted
        assert redirected_to(conn) == "/sign-in"
        assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "disabled"
      end
    end

    test "leaves unrelated paths alone" do
      conn = MagicLinkGate.call(conn_for(:get, "/auth/user/github"), [])
      refute conn.halted
    end
  end
end
