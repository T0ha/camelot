defmodule CamelotWeb.Plugs.RegistrationGateTest do
  use CamelotWeb.ConnCase, async: false

  alias Camelot.Accounts.User
  alias CamelotWeb.Plugs.RegistrationGate

  setup do
    original = Application.fetch_env!(:camelot, :registration_enabled)
    on_exit(fn -> Application.put_env(:camelot, :registration_enabled, original) end)
    :ok
  end

  defp request_conn(email) do
    :post
    |> build_conn("/auth/user/magic_link/request", %{"user" => %{"email" => email}})
    |> Plug.Conn.fetch_query_params()
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Phoenix.Controller.fetch_flash()
  end

  describe "when registration is enabled" do
    setup do
      Application.put_env(:camelot, :registration_enabled, true)
      :ok
    end

    test "lets any request through" do
      conn = RegistrationGate.call(request_conn("anyone@example.com"), [])
      refute conn.halted
    end
  end

  describe "when registration is disabled" do
    setup do
      Application.put_env(:camelot, :registration_enabled, false)
      :ok
    end

    test "lets a known email through" do
      Ash.Seed.seed!(User, %{email: "invited@example.com", role: :user})

      conn = RegistrationGate.call(request_conn("invited@example.com"), [])
      refute conn.halted
    end

    test "halts an unknown email with a flash + redirect" do
      conn = RegistrationGate.call(request_conn("stranger@example.com"), [])

      assert conn.halted
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "invite-only"
      assert Phoenix.ConnTest.redirected_to(conn) == "/sign-in"
    end

    test "halts an empty email" do
      conn = RegistrationGate.call(request_conn(""), [])
      assert conn.halted
    end

    test "is a no-op for non-matching paths" do
      conn =
        :get
        |> build_conn("/")
        |> Plug.Conn.fetch_query_params()
        |> Phoenix.ConnTest.init_test_session(%{})

      assert RegistrationGate.call(conn, []) == conn
    end
  end
end
