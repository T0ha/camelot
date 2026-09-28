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

    # An install that needs an org owner's approval, or one the user
    # backed out of, comes back with no installation_id at all — a
    # different place to lose someone than an id we could not parse.
    test "a callback with no installation_id at all is its own reason", ctx do
      %{conn: conn} = register_and_log_in_user(ctx)

      get(conn, ~p"/github/setup")

      assert %{properties: %{reason: :missing_installation_id}} = captured_failure()
    end
  end

  # `github_setup_succeeded` is a named step of the activation funnel,
  # and its three properties are read straight out of GitHub's
  # payload — a misspelt key would leave the step reporting nothing
  # for as long as nobody looked.
  describe "success telemetry" do
    setup do
      configure_github_app()
      :ok
    end

    test "a completed connect reports the installation it created", ctx do
      %{conn: conn, user: user} = register_and_log_in_user(ctx)
      installation_id = System.unique_integer([:positive])

      stub_installation(installation_id, %{
        "account" => %{"login" => "acme", "type" => "Organization"},
        "repository_selection" => "selected"
      })

      conn = complete_setup(conn, user, installation_id)

      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "GitHub App connected"

      assert %{distinct_id: distinct_id, properties: properties} = captured_success()
      assert distinct_id == user.id
      assert properties.installation_id == installation_id
      assert properties.account_type == "Organization"
      assert properties.repository_selection == "selected"
    end

    # An App installed on a single repository is a common way to end
    # up with a project Camelot cannot clone, so the two selections
    # have to stay distinguishable.
    test "an all-repositories installation is distinguishable", ctx do
      %{conn: conn, user: user} = register_and_log_in_user(ctx)
      installation_id = System.unique_integer([:positive])

      stub_installation(installation_id, %{
        "account" => %{"login" => "acme-user", "type" => "User"},
        "repository_selection" => "all"
      })

      complete_setup(conn, user, installation_id)

      assert %{properties: properties} = captured_success()
      assert properties.account_type == "User"
      assert properties.repository_selection == "all"
    end

    test "a GitHub outage is reported as an http failure, not a success", ctx do
      %{conn: conn, user: user} = register_and_log_in_user(ctx)
      installation_id = System.unique_integer([:positive])

      Req.Test.stub(__MODULE__, &Plug.Conn.send_resp(&1, 503, "nope"))

      complete_setup(conn, user, installation_id)

      refute captured_success()
      assert %{properties: %{reason: :http_error, http_status: 503}} = captured_failure()
    end
  end

  defp complete_setup(conn, user, installation_id) do
    state = GithubSetupController.state_token(user.id)

    get(conn, ~p"/github/setup?installation_id=#{installation_id}&state=#{state}")
  end

  # `fetch_installation/1` calls `Req.get/1` directly, so the only
  # seam is Req's own global default options. Safe here because the
  # case is `async: false`: ExUnit runs no other module alongside it.
  defp configure_github_app do
    previous_req = Application.get_env(:req, :default_options, [])
    Req.default_options(plug: {Req.Test, __MODULE__}, retry: false)
    on_exit(fn -> Application.put_env(:req, :default_options, previous_req) end)

    Application.put_env(:camelot, :github_app,
      app_id: "123",
      slug: "camelot-dev",
      client_id: "Iv1.abc",
      client_secret: "secret",
      private_key: Base.encode64(generate_pem()),
      webhook_secret: "whsecret"
    )
  end

  defp generate_pem do
    key = :public_key.generate_key({:rsa, 2_048, 65_537})
    der = :public_key.der_encode(:RSAPrivateKey, key)
    :public_key.pem_encode([{:RSAPrivateKey, der, :not_encrypted}])
  end

  defp stub_installation(installation_id, attrs) do
    body = Map.put(attrs, "id", installation_id)

    Req.Test.stub(__MODULE__, &Req.Test.json(&1, body))
  end

  defp captured_success do
    Enum.find(PostHog.Test.all_captured(), &(&1.event == "github_setup_succeeded"))
  end

  defp captured_failure do
    Enum.find(PostHog.Test.all_captured(), &(&1.event == "github_setup_failed"))
  end
end
