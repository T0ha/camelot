defmodule Camelot.Board.PrApproval do
  @moduledoc """
  Approves and merges a task's pull request on GitHub, then moves the
  task to `done`.

  "Approve PR" used to be a purely local state change: the card landed
  in Done while the PR stayed open forever. The merge is now the
  authoritative step — the task only completes when GitHub reports the
  PR merged, so `done` never lies about the state of the branch.

  The approving review is best effort. The runner opens the PR with the
  same installation token, so the App is usually the PR author and
  GitHub refuses self-approval with a `422`; that is logged and ignored,
  mirroring the degrade-don't-block approach of
  `Camelot.Board.Changes.CheckPrStatus.best_effort_check_runs/1`.

  Tasks with no PR (local projects, or a project not linked to a GitHub
  repo) skip GitHub entirely and just complete.
  """

  alias Camelot.Board.Changes.CheckPrStatus
  alias Camelot.Board.Task
  alias Camelot.Github.PullRequestApi

  require Logger

  @default_merge_method :squash

  @type reason ::
          :not_mergeable
          | :conflict
          | :forbidden
          | :not_found
          | {:github, integer()}
          | {:transport, term()}
          | {:transition, term()}

  @doc """
  Approves and merges the task's PR, completing the task on success.

  Returns `{:error, reason}` without transitioning the task when the
  merge is refused — a refused merge means the PR is still open, and
  the board must say so.
  """
  @spec approve_and_merge(Task.t()) :: {:ok, Task.t()} | {:error, reason()}
  def approve_and_merge(task) do
    task = Ash.load!(task, [:project, creator: [:github_installations]], authorize?: false)

    merge_and_complete(task, pull_request(task))
  end

  @doc """
  The configured merge method.

  Reads `config :camelot, :pr_merge, method: …`, falling back to
  `#{inspect(@default_merge_method)}`. The repository must allow that
  method, otherwise GitHub answers `405`.
  """
  @spec merge_method() :: :squash | :merge | :rebase
  def merge_method do
    :camelot
    |> Application.get_env(:pr_merge, [])
    |> Keyword.get(:method, @default_merge_method)
  end

  @doc """
  Classifies a merge reply from `Camelot.Github.PullRequestApi`.

  GitHub's merge endpoint overloads several failures onto statuses that
  mean very different things to the user, so each gets its own reason.
  """
  @spec merge_outcome({:ok, map()} | {:error, term()}) ::
          {:ok, :merged} | {:error, reason()}
  def merge_outcome({:ok, _body}), do: {:ok, :merged}
  def merge_outcome({:error, {:http_error, 403, _body}}), do: {:error, :forbidden}
  def merge_outcome({:error, {:http_error, 404, _body}}), do: {:error, :not_found}
  def merge_outcome({:error, {:http_error, 405, _body}}), do: {:error, :not_mergeable}
  def merge_outcome({:error, {:http_error, 409, _body}}), do: {:error, :conflict}

  def merge_outcome({:error, {:http_error, status, _body}}) do
    {:error, {:github, status}}
  end

  def merge_outcome({:error, reason}), do: {:error, {:transport, reason}}

  @doc "Actionable flash copy for a failed approve-and-merge."
  @spec error_message(reason()) :: String.t()
  def error_message(:not_mergeable) do
    "GitHub refused the merge — branch protection, required checks, " <>
      "or the repository not allowing this merge method."
  end

  def error_message(:conflict) do
    "GitHub could not merge the PR — the branch has conflicts or the " <>
      "head commit moved. Ask for changes to rebase it."
  end

  def error_message(:forbidden) do
    "GitHub denied the merge — the App installation needs Contents " <>
      "(read/write) on this repository."
  end

  def error_message(:not_found) do
    "GitHub could not find the pull request — check the project's " <>
      "owner/repo and that the App is installed on it."
  end

  def error_message({:github, status}) do
    "GitHub rejected the merge with HTTP #{status}. The PR is still open."
  end

  def error_message({:transport, _reason}) do
    "Could not reach GitHub to merge the PR. The PR is still open."
  end

  def error_message({:transition, _reason}) do
    "The PR was merged but the task could not be moved to done."
  end

  @doc """
  True for GitHub's refusal to let an author approve their own PR.

  Matched on the message text rather than the status alone: a `422`
  from this endpoint can also mean a genuinely invalid review, which is
  worth a warning, while self-approval is expected and routine.
  """
  @spec self_approval_error?(term()) :: boolean()
  def self_approval_error?({:http_error, 422, body}) do
    body |> inspect() |> String.contains?("approve your own")
  end

  def self_approval_error?(_reason), do: false

  # `{owner, repo, pr_number}` when the task has a PR to merge, `:none`
  # for local projects and tasks that never opened one.
  defp pull_request(%{pr_number: nil}), do: :none
  defp pull_request(%{project: %{github_owner: nil}}), do: :none
  defp pull_request(%{project: %{github_repo: nil}}), do: :none

  defp pull_request(%{pr_number: pr_number, project: %{github_owner: owner, github_repo: repo}}) do
    {owner, repo, pr_number}
  end

  defp pull_request(_task), do: :none

  defp merge_and_complete(task, :none), do: complete(task)

  defp merge_and_complete(task, {owner, repo, pr_number}) do
    opts = [installation_id: CheckPrStatus.installation_id(task)]
    approve(owner, repo, pr_number, opts)

    owner
    |> merge_pull_request(repo, pr_number, opts)
    |> merge_outcome()
    |> complete_merged(task)
  end

  defp merge_pull_request(owner, repo, pr_number, opts) do
    api = PullRequestApi.impl()
    opts = Keyword.put(opts, :merge_method, merge_method())

    api.merge_pull_request(owner, repo, pr_number, opts)
  end

  defp complete_merged({:ok, :merged}, task), do: complete(task)

  defp complete_merged({:error, reason}, task) do
    Logger.warning(
      "Task #{task.id}: PR merge failed (#{inspect(reason)}); " <>
        "leaving the task in the pr stage"
    )

    {:error, reason}
  end

  defp complete(task) do
    case Ash.update(task, %{}, action: :complete) do
      {:ok, updated} -> {:ok, updated}
      {:error, error} -> {:error, {:transition, error}}
    end
  end

  # Best effort: the review is a courtesy record on the PR, the merge
  # is what matters, so every approval failure is logged and swallowed.
  defp approve(owner, repo, pr_number, opts) do
    api = PullRequestApi.impl()

    log_approval(api.approve_pull_request(owner, repo, pr_number, opts))
  end

  defp log_approval({:ok, _review}), do: :ok

  defp log_approval({:error, reason}) do
    log_approval_error(reason, self_approval_error?(reason))
  end

  defp log_approval_error(reason, true) do
    Logger.info(
      "GitHub refused the approving review (#{inspect(reason)}); " <>
        "the App authored the PR — merging anyway"
    )
  end

  defp log_approval_error(reason, false) do
    Logger.warning(
      "Could not submit the approving review (#{inspect(reason)}); " <>
        "merging anyway"
    )
  end
end
