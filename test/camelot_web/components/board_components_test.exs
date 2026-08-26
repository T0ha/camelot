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

    test "renders the waiting_for_slot emoji with its own title" do
      html =
        render_component(&BoardComponents.state_badge/1, state: :waiting_for_slot)

      assert html =~ "⏳"
      assert html =~ ~s(title="Waiting for a runner slot")
      assert html =~ "badge-ghost"
    end
  end

  describe "task_card/1" do
    defp task(attrs) do
      Map.merge(
        %{
          id: "11111111-1111-1111-1111-111111111111",
          title: "Some task",
          description: nil,
          state: :in_progress,
          stage: :executing,
          priority: 0,
          pr_url: nil,
          pr_number: nil,
          last_error: nil,
          waiting_for_slot?: false
        },
        attrs
      )
    end

    test "shows the running badge for a task holding a runner slot" do
      html = render_component(&BoardComponents.task_card/1, task: task(%{}))

      assert html =~ "🔃"
      assert html =~ ~s(title="In progress")
    end

    test "shows the waiting badge for a dispatched task with no runner slot" do
      html =
        render_component(&BoardComponents.task_card/1,
          task: task(%{waiting_for_slot?: true})
        )

      assert html =~ "⏳"
      assert html =~ ~s(title="Waiting for a runner slot")
      refute html =~ "🔃"
    end

    test "ignores the waiting flag for a task that is not in progress" do
      html =
        render_component(&BoardComponents.task_card/1,
          task: task(%{state: :waiting_for_input, waiting_for_slot?: true})
        )

      assert html =~ "💬"
      refute html =~ "⏳"
    end

    test "falls back to the task state when the aggregate was not loaded" do
      html =
        render_component(&BoardComponents.task_card/1,
          task: task(%{waiting_for_slot?: %Ash.NotLoaded{type: :aggregate}})
        )

      assert html =~ "🔃"
    end
  end
end
