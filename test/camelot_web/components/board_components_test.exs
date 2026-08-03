defmodule CamelotWeb.BoardComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias CamelotWeb.BoardComponents

  describe "state_badge/1" do
    test "renders the queued emoji with a humanized title and badge class" do
      html = render_component(&BoardComponents.state_badge/1, state: :queued)

      assert html =~ "⏳"
      assert html =~ ~s(title="Queued")
      assert html =~ "badge-ghost"
    end

    test "renders the in_progress emoji with a humanized title and badge class" do
      html = render_component(&BoardComponents.state_badge/1, state: :in_progress)

      assert html =~ "🔃"
      assert html =~ ~s(title="In progress")
      assert html =~ "badge-primary"
    end

    test "renders the waiting_for_input emoji with a humanized title and badge class" do
      html =
        render_component(&BoardComponents.state_badge/1, state: :waiting_for_input)

      assert html =~ "💬"
      assert html =~ ~s(title="Waiting for input")
      assert html =~ "badge-warning"
    end

    test "renders the error emoji with a humanized title and badge class" do
      html = render_component(&BoardComponents.state_badge/1, state: :error)

      assert html =~ "⚠️"
      assert html =~ ~s(title="Error")
      assert html =~ "badge-error"
    end
  end
end
