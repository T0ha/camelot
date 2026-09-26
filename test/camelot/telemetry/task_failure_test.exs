defmodule Camelot.Telemetry.TaskFailureTest do
  use ExUnit.Case, async: true

  alias Camelot.Telemetry.TaskFailure

  defp task(stage, last_error), do: %{stage: stage, last_error: last_error}

  test "a failed clone is attributed to the clone stage, not to the agent" do
    error = "[entrypoint] cloning https://github.com/acme/app\nfatal: Authentication failed"

    assert TaskFailure.classify(task(:planning, error)) == {:clone, :git_auth_failed}
  end

  test "an image that cannot be pulled fails at boot" do
    assert TaskFailure.classify(task(:todo, "pull access denied for camelot/runner")) ==
             {:boot, :image_pull_failed}
  end

  test "a plan-less planning run is an empty plan in the plan stage" do
    error = "Agent finished planning without producing a plan."

    assert TaskFailure.classify(task(:planning, error)) == {:plan, :empty_plan}
  end

  test "an interrupted run is distinguishable from an agent failure" do
    error = "This run was interrupted because the runner was replaced."

    assert TaskFailure.classify(task(:executing, error)) == {:execute, :interrupted}
  end

  test "the runner's unexplained failure keeps its stage" do
    error = "The runner exited with a non-zero status without reporting a reason."

    assert TaskFailure.classify(task(:executing, error)) == {:execute, :agent_exit_nonzero}
  end

  test "unrecognised wording degrades to :unexplained rather than a free string" do
    assert TaskFailure.classify(task(:pr, "something nobody has seen before")) ==
             {:pr, :unexplained}
  end

  test "a task with no error at all still classifies" do
    assert {stage, reason} = TaskFailure.classify(task(:executing, nil))
    assert stage in TaskFailure.stages()
    assert reason in TaskFailure.reasons()
  end

  test "every classification is a member of the documented enums" do
    errors = [
      nil,
      "Authentication failed",
      "manifest unknown",
      "no suitable node",
      "timed out waiting for the agent",
      "no PR URL was produced",
      "exit code 3",
      "[entrypoint] something"
    ]

    for stage <- [:draft, :todo, :planning, :executing, :pr, :done], error <- errors do
      {classified_stage, reason} = TaskFailure.classify(task(stage, error))

      assert classified_stage in TaskFailure.stages()
      assert reason in TaskFailure.reasons()
    end
  end
end
