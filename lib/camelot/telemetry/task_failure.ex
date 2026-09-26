defmodule Camelot.Telemetry.TaskFailure do
  @moduledoc """
  Works out *where* and *why* a task run failed, from the task alone.

  `task_errored` used to carry nothing but the task id, which made a
  runner that could not clone the repository indistinguishable from an
  agent that produced a bad plan — the exact question the
  "`[entrypoint] cloning … Authentication failed`" reports left open.

  The task already carries both halves of the answer: `stage` says how
  far the run got, and `last_error` is the message
  `Camelot.Runtime.TaskRunner` wrote when it gave up. Classifying here
  rather than at the `mark_error` call sites keeps the runner free of
  telemetry, at the price of matching on message text — so the enum
  has an `:unexplained` member and unknown wording degrades to it
  instead of leaking an unbounded string.
  """

  alias Camelot.Board.Task

  @typedoc "Phase of a run a failure is attributed to."
  @type stage :: :clone | :boot | :plan | :execute | :pr

  @typedoc "Bounded cause of a failed run."
  @type reason ::
          :git_auth_failed
          | :image_pull_failed
          | :provision_failed
          | :runner_died
          | :agent_exit_nonzero
          | :empty_plan
          | :empty_output
          | :interrupted
          | :timeout
          | :unexplained

  @typedoc """
  Anything carrying the two fields a failure is read from.

  The plain-map arm is not redundant: a bare map type in a spec is a
  *closed* one, so `Task.t()` alone would exclude it, and vice versa.
  """
  @type failed :: Task.t() | %{stage: atom(), last_error: String.t() | nil}

  @stages [:clone, :boot, :plan, :execute, :pr]

  @reasons [
    :git_auth_failed,
    :image_pull_failed,
    :provision_failed,
    :runner_died,
    :agent_exit_nonzero,
    :empty_plan,
    :empty_output,
    :interrupted,
    :timeout,
    :unexplained
  ]

  # Matched in order, first hit wins, so the specific causes come
  # before the generic "it exited badly" catch. A dead runner's
  # container log tail is *prepended* to the generic summary by
  # `TaskRunner.runner_died_message/2`, which is why the causes that
  # only ever appear in such a tail are matched ahead of it.
  #
  # Every needle below is taken from a message the application really
  # writes: `Camelot.Runtime.TaskRunner` and
  # `Camelot.Board.Interruption` are the only two writers of
  # `last_error`. A reason with no writer would be a promise the
  # funnel cannot keep, so `task_failure_test.exs` pins both halves —
  # each real message classifies, and each advertised reason is
  # reachable.
  @patterns [
    {["authentication failed", "could not read username", "invalid username or token", "permission denied (publickey)"],
     :git_auth_failed},
    {["pull access denied", "manifest unknown", "no such image", "image pull"], :image_pull_failed},
    {["no suitable node", "could not provision", "failed to provision", "failed to start"], :provision_failed},
    {["without producing a plan"], :empty_plan},
    {["without producing any output"], :empty_output},
    {["interrupted because", "runner was interrupted"], :interrupted},
    {["timed out", "timeout"], :timeout},
    {["exited before producing output"], :runner_died},
    {["non-zero status", "exit code", "exited with"], :agent_exit_nonzero}
  ]

  @doc "Every stage `classify/1` can return."
  @spec stages() :: [stage()]
  def stages, do: @stages

  @doc "Every reason `classify/1` can return."
  @spec reasons() :: [reason()]
  def reasons, do: @reasons

  @doc """
  Classifies a failed task into `{stage, reason}`.
  """
  @spec classify(failed()) :: {stage(), reason()}
  def classify(%{last_error: last_error} = task) do
    message = String.downcase(to_string(last_error))
    reason = reason(message)

    {stage(reason, message, Map.get(task, :stage)), reason}
  end

  @spec reason(String.t()) :: reason()
  defp reason(message) do
    case Enum.find(@patterns, fn {needles, _reason} -> contains?(message, needles) end) do
      {_needles, reason} -> reason
      nil -> :unexplained
    end
  end

  # A clone or an image pull happens before any Ash stage transition,
  # so those reasons name the stage themselves; everything else takes
  # the stage the board already shows.
  @spec stage(reason(), String.t(), atom()) :: stage()
  defp stage(:git_auth_failed, _message, _task_stage), do: :clone
  defp stage(:image_pull_failed, _message, _task_stage), do: :boot
  defp stage(:provision_failed, _message, _task_stage), do: :boot

  defp stage(_reason, message, task_stage) do
    case {String.contains?(message, "[entrypoint]"), task_stage} do
      {true, _task_stage} -> :boot
      {false, :planning} -> :plan
      {false, :executing} -> :execute
      {false, :pr} -> :pr
      {false, _other} -> :boot
    end
  end

  defp contains?(message, needles), do: Enum.any?(needles, &String.contains?(message, &1))
end
