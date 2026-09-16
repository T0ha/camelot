defmodule CamelotWeb.GithubEmailControllerTest do
  use CamelotWeb.ConnCase, async: false

  alias Camelot.Accounts.User
  alias Camelot.Github.Installation
  alias CamelotWeb.GithubLoginFlow

  defp seed_user!(attrs \\ %{}) do
    defaults = %{
      email: "prompt-#{System.unique_integer([:positive])}@example.com",
      confirmed_at: DateTime.utc_now()
    }

    Ash.Seed.seed!(User, Map.merge(defaults, attrs))
  end

  defp install!(user) do
    Ash.Seed.seed!(Installation, %{
      installation_id: System.unique_integer([:positive]),
      account_login: "octocat",
      account_type: :user,
      user_id: user.id
    })
  end

  defp signed_in(conn, user, session \\ %{}) do
    %{conn: conn} = log_in_user(conn, user)
    Enum.reduce(session, conn, fn {k, v}, acc -> Plug.Conn.put_session(acc, k, v) end)
  end

  defp reload!(user), do: Ash.get!(User, user.id, authorize?: false)

  describe "edit" do
    test "redirects anonymous visitors to sign-in", %{conn: conn} do
      conn = get(conn, ~p"/github/email")

      assert redirected_to(conn) == "/sign-in"
    end

    test "redirects home when nothing is pending", %{conn: conn} do
      user = seed_user!()

      conn = conn |> signed_in(user) |> get(~p"/github/email")

      assert redirected_to(conn) == "/"
    end

    test "shows both addresses", %{conn: conn} do
      user = seed_user!(%{email: "old@example.com"})

      conn =
        conn
        |> signed_in(user, %{github_pending_email: "new@example.com"})
        |> get(~p"/github/email")

      body = html_response(conn, 200)
      assert body =~ "old@example.com"
      assert body =~ "new@example.com"
    end
  end

  describe "update" do
    test "adopting moves the email and clears the pending session key", %{conn: conn} do
      user = seed_user!(%{email: "old2@example.com"})
      install!(user)

      conn =
        conn
        |> signed_in(user, %{github_pending_email: "new2@example.com"})
        |> post(~p"/github/email", %{"decision" => "update"})

      assert redirected_to(conn) == "/"
      refute Plug.Conn.get_session(conn, GithubLoginFlow.pending_email_key())
      assert to_string(reload!(user).email) == "new2@example.com"
    end

    test "keeping records the decline and leaves the email alone", %{conn: conn} do
      user = seed_user!(%{email: "old3@example.com"})
      install!(user)

      conn =
        conn
        |> signed_in(user, %{github_pending_email: "new3@example.com"})
        |> post(~p"/github/email", %{"decision" => "keep"})

      assert redirected_to(conn) == "/"

      reloaded = reload!(user)
      assert to_string(reloaded.email) == "old3@example.com"
      assert to_string(reloaded.github_email_declined) == "new3@example.com"
    end

    test "refuses an address owned by another account", %{conn: conn} do
      seed_user!(%{email: "occupied@example.com"})
      user = seed_user!(%{email: "old4@example.com"})
      install!(user)

      conn =
        conn
        |> signed_in(user, %{github_pending_email: "occupied@example.com"})
        |> post(~p"/github/email", %{"decision" => "update"})

      assert redirected_to(conn) == "/"

      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~
               "already belongs to another Camelot account"

      assert to_string(reload!(user).email) == "old4@example.com"
    end

    test "ignores an email supplied only as a form param", %{conn: conn} do
      user = seed_user!(%{email: "old5@example.com"})

      conn =
        conn
        |> signed_in(user)
        |> post(~p"/github/email", %{
          "decision" => "update",
          "email" => "attacker@example.com"
        })

      assert redirected_to(conn) == "/"
      assert to_string(reload!(user).email) == "old5@example.com"
    end

    test "redirects anonymous visitors to sign-in", %{conn: conn} do
      conn = post(conn, ~p"/github/email", %{"decision" => "update"})

      assert redirected_to(conn) == "/sign-in"
    end
  end
end
