defmodule CamelotWeb.UserProfileLiveTest do
  use CamelotWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Camelot.Accounts.Credential
  alias Camelot.Github.Installation

  require Ash.Query

  setup :register_and_log_in_user

  describe "SSH key section" do
    test "renders the section heading", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/profile")
      assert html =~ "SSH key"
    end

    test "ignores unrelated PubSub messages without crashing", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/profile")

      send(view.pid, {:some_unexpected_message, :payload})

      assert render(view) =~ "SSH key"
    end

    test "auto-backfills a default key for a legacy user on first mount",
         %{conn: conn, user: user} do
      # `register_and_log_in_user` uses `Ash.Seed.seed!`, which skips
      # the resource-level change. The LiveView mount is the safety net.
      assert ssh_credentials_for(user.id) == []

      {:ok, _view, html} = live(conn, ~p"/profile")

      [cred] = ssh_credentials_for(user.id)
      assert cred.name == "default"
      assert cred.metadata["source"] == "server_generated"

      # Public key is rendered (in a copyable element).
      assert html =~ cred.metadata["public_key"]
      assert html =~ cred.metadata["fingerprint"]
    end

    test "shows a rotate button when a key exists", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/profile")
      assert has_element?(view, "[phx-click=open_rotate_modal]")
    end

    test "rotating replaces the credential value and updates metadata",
         %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, ~p"/profile")

      [before_rotation] = ssh_credentials_for_with_value(user.id)
      old_value = before_rotation.value
      old_fp = before_rotation.metadata["fingerprint"]

      view
      |> element("button[phx-click=confirm_rotate_ssh_key]")
      |> render_click()

      [after_rotation] = ssh_credentials_for_with_value(user.id)

      assert after_rotation.value != old_value
      assert after_rotation.metadata["fingerprint"] != old_fp
      assert String.starts_with?(after_rotation.metadata["fingerprint"], "SHA256:")
      assert {:ok, _, _} = DateTime.from_iso8601(after_rotation.metadata["rotated_at"])
    end
  end

  describe "notification preferences section" do
    test "renders the section heading", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/profile")
      assert html =~ "Email notifications"
    end

    test "toggling a checkbox off and submitting persists the change", %{
      conn: conn,
      user: user
    } do
      {:ok, view, _html} = live(conn, ~p"/profile")

      view
      |> form("#notification-prefs-form", %{
        "prefs" => %{
          "notify_on_waiting_for_input" => "true",
          "notify_on_error" => "false",
          "notify_on_done" => "true"
        }
      })
      |> render_submit()

      updated = Ash.get!(Camelot.Accounts.User, user.id)
      refute updated.notify_on_error
      assert updated.notify_on_waiting_for_input
      assert updated.notify_on_done
    end

    test "shows a confirmation flash after saving", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/profile")

      html =
        view
        |> form("#notification-prefs-form", %{
          "prefs" => %{
            "notify_on_waiting_for_input" => "true",
            "notify_on_error" => "true",
            "notify_on_done" => "true"
          }
        })
        |> render_submit()

      assert html =~ "Preferences saved"
    end
  end

  describe "GitHub App section" do
    setup do
      previous = Application.get_env(:camelot, :github_app)
      on_exit(fn -> Application.put_env(:camelot, :github_app, previous) end)
      :ok
    end

    test "warns when no GitHub App is configured for this deployment", %{conn: conn} do
      Application.put_env(:camelot, :github_app, [])

      {:ok, _view, html} = live(conn, ~p"/profile")
      assert html =~ "No GitHub App is configured"
    end

    test "shows a connect link when configured but not connected", %{conn: conn} do
      put_app_configured()

      {:ok, _view, html} = live(conn, ~p"/profile")
      assert html =~ "Connect GitHub App"
      refute html =~ "Disconnect"
    end

    test "shows the connected account and a disconnect button when linked", %{
      conn: conn,
      user: user
    } do
      put_app_configured()
      link_installation!(user, "acme-org")

      {:ok, _view, html} = live(conn, ~p"/profile")
      assert html =~ "acme-org"
      assert html =~ "Disconnect"
    end

    test "disconnecting removes the installation and shows the connect link again", %{
      conn: conn,
      user: user
    } do
      put_app_configured()
      link_installation!(user, "acme-org")

      {:ok, view, _html} = live(conn, ~p"/profile")

      html =
        view
        |> element("button[phx-click=disconnect_github_app]")
        |> render_click()

      assert html =~ "GitHub App disconnected"
      assert html =~ "Connect GitHub App"
      refute html =~ "acme-org"

      assert Installation
             |> Ash.Query.filter(user_id == ^user.id)
             |> Ash.read!(authorize?: false) == []
    end
  end

  defp put_app_configured do
    Application.put_env(:camelot, :github_app,
      app_id: "123",
      slug: "camelot-dev",
      client_id: "Iv1.abc",
      client_secret: "secret",
      private_key: Base.encode64("not-a-real-key"),
      webhook_secret: "whsecret"
    )
  end

  defp link_installation!(user, account_login) do
    {:ok, installation} =
      Ash.create(
        Installation,
        %{
          installation_id: System.unique_integer([:positive]),
          account_login: account_login,
          account_type: :organization
        },
        authorize?: false
      )

    {:ok, linked} =
      Ash.update(installation, %{user_id: user.id}, action: :link_user, actor: user)

    linked
  end

  defp ssh_credentials_for(user_id) do
    Credential
    |> Ash.Query.filter(user_id == ^user_id and kind == :ssh_private_key)
    |> Ash.read!()
  end

  defp ssh_credentials_for_with_value(user_id) do
    Credential
    |> Ash.Query.filter(user_id == ^user_id and kind == :ssh_private_key)
    |> Ash.Query.load(:value)
    |> Ash.read!()
  end
end
