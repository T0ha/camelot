defmodule CamelotWeb.UserProfileLiveTest do
  use CamelotWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Camelot.Accounts.Credential

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
