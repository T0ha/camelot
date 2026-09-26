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

  # The messages below are the ones the application actually writes to
  # `last_error`. They are quoted verbatim from their source so that
  # re-wording a runner message without re-classifying it fails here
  # rather than silently moving that failure into `:unexplained` —
  # which is how the first four of them were missed.
  describe "the messages the application actually writes" do
    # `Camelot.Runtime.TaskRunner.empty_error_reason/1`
    test "an agent that produced nothing is :empty_output, not :unexplained" do
      assert TaskFailure.classify(task(:executing, "Agent finished without producing any output.")) ==
               {:execute, :empty_output}

      assert TaskFailure.classify(task(:planning, "Agent finished without producing any output after 3 attempts.")) ==
               {:plan, :empty_output}
    end

    # `Camelot.Runtime.TaskRunner.handle_info/2` — RunnerPool refused.
    test "a runner that never started is a provisioning failure at boot" do
      error = "Runner failed to start: {:error, :no_capacity}"

      assert TaskFailure.classify(task(:todo, error)) == {:boot, :provision_failed}
    end

    # `Camelot.Runtime.TaskRunner.runner_died_message/2`, no log tail.
    test "a runner that died before streaming output is :runner_died" do
      error = "runner exited before producing output ({:shutdown, :closed})"

      assert TaskFailure.classify(task(:executing, error)) == {:execute, :runner_died}
    end

    # `Camelot.Board.Interruption.give_up/2`
    test "hitting the interruption re-queue cap is :interrupted" do
      error =
        "Re-queued 3 times after the runner was interrupted, without " <>
          "completing a run. Last interruption: node drained"

      assert TaskFailure.classify(task(:executing, error)) == {:execute, :interrupted}
    end

    # `runner_died_message/2` prepends the container log tail, so the
    # real cause in the tail must win over the generic summary.
    test "a log tail's cause beats the generic died-before-output summary" do
      error =
        "[entrypoint] cloning https://github.com/acme/app\n" <>
          "fatal: Authentication failed\n\n" <>
          "runtime detail: runner exited before producing output ({:exit, 128})"

      assert TaskFailure.classify(task(:planning, error)) == {:clone, :git_auth_failed}
    end
  end

  test "every classification is a member of the documented enums" do
    errors = [
      nil,
      "Authentication failed",
      "manifest unknown",
      "no suitable node",
      "timed out waiting for the agent",
      "Agent finished without producing any output.",
      "exit code 3",
      "[entrypoint] something"
    ]

    for stage <- [:draft, :todo, :planning, :executing, :pr, :done], error <- errors do
      {classified_stage, reason} = TaskFailure.classify(task(stage, error))

      assert classified_stage in TaskFailure.stages()
      assert reason in TaskFailure.reasons()
    end
  end

  test "no advertised reason is unreachable" do
    # Every member of `reasons/0` must be producible from some message,
    # or it is documentation for a failure that cannot happen.
    samples = [
      {"fatal: Authentication failed", :git_auth_failed},
      {"pull access denied", :image_pull_failed},
      {"Runner failed to start: {:error, :no_capacity}", :provision_failed},
      {"Agent finished planning without producing a plan.", :empty_plan},
      {"Agent finished without producing any output.", :empty_output},
      {"This run was interrupted because the node drained.", :interrupted},
      {"timed out waiting for the agent", :timeout},
      {"runner exited before producing output ({:exit, 1})", :runner_died},
      {"The runner exited with a non-zero status without reporting a reason.", :agent_exit_nonzero},
      {"something nobody has seen before", :unexplained}
    ]

    for {message, expected} <- samples do
      assert {_stage, ^expected} = TaskFailure.classify(task(:executing, message))
    end

    assert Enum.sort(Enum.map(samples, &elem(&1, 1))) ==
             Enum.sort(TaskFailure.reasons())
  end
end
