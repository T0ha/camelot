defmodule CamelotWeb.GithubSetupControllerTest do
  use CamelotWeb.ConnCase, async: false

  alias CamelotWeb.GithubSetupController

  setup do
    previous = Application.get_env(:camelot, :github_app)
    Application.put_env(:camelot, :github_app, [])
    on_exit(fn -> Application.put_env(:camelot, :github_app, previous) end)
    :ok
  end

  describe "GET /github/setup" do
    test "redirects with an error when installation_id is missing", ctx do
      %{conn: conn} = register_and_log_in_user(ctx)

      conn = get(conn, ~p"/github/setup")

      assert redirected_to(conn) == ~p"/profile"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Missing installation_id"
    end

    test "redirects with an error when the state token is missing", ctx do
      %{conn: conn} = register_and_log_in_user(ctx)

      conn = get(conn, ~p"/github/setup?installation_id=1")

      assert redirected_to(conn) == ~p"/profile"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Could not connect"
    end

    test "redirects with an error when the state token was signed for a different user", ctx do
      %{conn: conn} = register_and_log_in_user(ctx)

      other_user_id = Ash.UUID.generate()
      state = GithubSetupController.state_token(other_user_id)

      conn = get(conn, ~p"/github/setup?installation_id=1&state=#{state}")

      assert redirected_to(conn) == ~p"/profile"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Could not connect"
    end

    test "redirects with an error when the App isn't configured, without calling GitHub", ctx do
      %{conn: conn, user: user} = register_and_log_in_user(ctx)

      state = GithubSetupController.state_token(user.id)

      conn = get(conn, ~p"/github/setup?installation_id=1&state=#{state}")

      assert redirected_to(conn) == ~p"/profile"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Could not connect"
    end
  end

  # Every failure branch has to be countable with a bounded `reason`:
  # before this, a failed connect left one `inspect(reason)` log line
  # and no event at all, so a user stuck here was invisible.
  describe "failure telemetry" do
    test "a missing state token is reported as such", ctx do
      %{conn: conn, user: user} = register_and_log_in_user(ctx)

      get(conn, ~p"/github/setup?installation_id=1")

      assert %{distinct_id: distinct_id, properties: properties} = captured_failure()
      assert distinct_id == user.id
      assert properties.reason == :missing_state
    end

    test "a state token signed for someone else is an actor mismatch", ctx do
      %{conn: conn} = register_and_log_in_user(ctx)
      state = GithubSetupController.state_token(Ash.UUID.generate())

      get(conn, ~p"/github/setup?installation_id=1&state=#{state}")

      assert %{properties: %{reason: :actor_mismatch}} = captured_failure()
    end

    test "an unconfigured GitHub App is distinguishable from a GitHub outage", ctx do
      %{conn: conn, user: user} = register_and_log_in_user(ctx)
      state = GithubSetupController.state_token(user.id)

      get(conn, ~p"/github/setup?installation_id=1&state=#{state}")

      assert %{properties: %{reason: :not_configured, http_status: nil}} = captured_failure()
    end

    test "a non-numeric installation id is reported as such", ctx do
      %{conn: conn, user: user} = register_and_log_in_user(ctx)
      state = GithubSetupController.state_token(user.id)

      get(conn, ~p"/github/setup?installation_id=abc&state=#{state}")

      assert %{properties: %{reason: :invalid_installation_id}} = captured_failure()
    end

    test "a callback with no installation_id at all is still counted", ctx do
      %{conn: conn} = register_and_log_in_user(ctx)

      get(conn, ~p"/github/setup")

      assert %{properties: %{reason: :invalid_installation_id}} = captured_failure()
    end
  end

  defp captured_failure do
    Enum.find(PostHog.Test.all_captured(), &(&1.event == "github_setup_failed"))
  end
end
