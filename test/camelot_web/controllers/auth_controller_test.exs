defmodule CamelotWeb.AuthControllerTest do
  use CamelotWeb.ConnCase, async: false

  alias AshAuthentication.Errors.AuthenticationFailed
  alias Camelot.Accounts.Errors.RegistrationDisabled
  alias Camelot.Accounts.User
  alias Camelot.Github.Installation
  alias CamelotWeb.AuthController

  @app_config [
    app_id: "123",
    slug: "camelot-dev",
    client_id: "Iv1.abc",
    client_secret: "secret",
    private_key: Base.encode64("-----BEGIN PRIVATE KEY-----\nabc\n-----END PRIVATE KEY-----\n"),
    webhook_secret: "whsecret"
  ]

  setup %{conn: conn} do
    previous = Application.get_env(:camelot, :github_app)
    on_exit(fn -> Application.put_env(:camelot, :github_app, previous) end)

    user =
      Ash.Seed.seed!(User, %{
        email: "signed-in-#{System.unique_integer([:positive])}@example.com",
        confirmed_at: DateTime.utc_now()
      })

    {:ok, token, _claims} = AshAuthentication.Jwt.token_for_user(user)
    user = %{user | __metadata__: Map.put(user.__metadata__, :token, token)}

    %{conn: Phoenix.ConnTest.init_test_session(conn, %{}), user: user}
  end

  defp with_metadata(user, extra) do
    %{user | __metadata__: Map.merge(user.__metadata__, extra)}
  end

  defp install!(user) do
    Ash.Seed.seed!(Installation, %{
      installation_id: System.unique_integer([:positive]),
      account_login: "octocat",
      account_type: :user,
      user_id: user.id
    })
  end

  test "emits [:camelot, :user, :signed_in] on success", %{conn: conn, user: user} do
    ref = :telemetry_test.attach_event_handlers(self(), [[:camelot, :user, :signed_in]])
    on_exit(fn -> :telemetry.detach(ref) end)

    AuthController.success(conn, {:strategy, :confirm}, user, "token")

    assert_received {[:camelot, :user, :signed_in], ^ref, %{}, %{user: received_user}}
    assert received_user.id == user.id
  end

  describe "GET /auth/user/github" do
    test "redirects to GitHub's authorize screen", %{conn: conn} do
      Application.put_env(:camelot, :github_app, @app_config)

      conn = get(conn, "/auth/user/github")

      location = redirected_to(conn, 302)
      assert location =~ "https://github.com/login/oauth/authorize"
      assert location =~ "client_id=Iv1.abc"
      assert location =~ "state="
      assert location =~ "redirect_uri=" <> URI.encode_www_form(url(~p"/auth/user/github/callback"))

      assert %{state: _} = Plug.Conn.get_session(conn, "user/github")
    end

    test "is refused when the GitHub App isn't configured", %{conn: conn} do
      Application.put_env(:camelot, :github_app, [])

      conn = get(conn, "/auth/user/github")

      assert redirected_to(conn) == "/sign-in"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "isn't configured"
    end
  end

  describe "GET /auth/user/github/callback" do
    test "a callback with no session state fails before any network call", %{conn: conn} do
      Application.put_env(:camelot, :github_app, @app_config)

      conn = get(conn, "/auth/user/github/callback", %{"code" => "abc", "state" => "xyz"})

      assert redirected_to(conn) == "/sign-in"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Authentication failed"
    end
  end

  describe "success/4 for the github callback" do
    setup do
      Application.put_env(:camelot, :github_app, [])
      :ok
    end

    test "signs the user in and lands on the board", %{conn: conn, user: user} do
      install!(user)

      conn = AuthController.success(conn, {:github, :callback}, user, "token")

      assert redirected_to(conn) == "/"
      assert conn.assigns.current_user.id == user.id
    end

    test "emits the signed_in telemetry event", %{conn: conn, user: user} do
      install!(user)
      ref = :telemetry_test.attach_event_handlers(self(), [[:camelot, :user, :signed_in]])
      on_exit(fn -> :telemetry.detach(ref) end)

      AuthController.success(conn, {:github, :callback}, user, "token")

      assert_received {[:camelot, :user, :signed_in], ^ref, %{}, %{user: received_user}}
      assert received_user.id == user.id
    end

    test "a pending github email routes to the prompt page", %{conn: conn, user: user} do
      install!(user)
      user = with_metadata(user, %{pending_github_email: "new@example.com"})

      conn = AuthController.success(conn, {:github, :callback}, user, "token")

      assert redirected_to(conn) == "/github/email"
      assert Plug.Conn.get_session(conn, :github_pending_email) == "new@example.com"
    end

    test "an unconfigured app never prompts for an install", %{conn: conn, user: user} do
      conn = AuthController.success(conn, {:github, :callback}, user, "token")

      assert redirected_to(conn) == "/"
    end
  end

  describe "failure/3" do
    setup %{conn: conn} do
      %{conn: Phoenix.Controller.fetch_flash(conn)}
    end

    test "surfaces the invite-only message", %{conn: conn} do
      reason =
        AuthenticationFailed.exception(
          caused_by: %Ash.Error.Forbidden{
            errors: [RegistrationDisabled.exception([])]
          }
        )

      conn = AuthController.failure(conn, {:github, :callback}, reason)

      assert redirected_to(conn) == "/sign-in"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "invite-only"
    end

    test "falls back to the generic message", %{conn: conn} do
      conn = AuthController.failure(conn, {:github, :callback}, :boom)

      assert Phoenix.Flash.get(conn.assigns.flash, :error) == "Authentication failed"
    end
  end
end
