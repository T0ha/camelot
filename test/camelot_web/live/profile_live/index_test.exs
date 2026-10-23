defmodule CamelotWeb.ProfileLive.IndexTest do
  use CamelotWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  setup :register_and_log_in_user

  test "/profile redirects to the SSH key screen", %{conn: conn} do
    assert {:error, {:live_redirect, %{to: "/profile/ssh-key"}}} =
             live(conn, ~p"/profile")
  end

  test "setup steps hand off to the split profile screens" do
    assert CamelotWeb.OnboardingComponents.step_path(:github) ==
             "/profile/github"

    assert CamelotWeb.OnboardingComponents.step_path(:claude_token) ==
             "/profile/api-keys"
  end
end
