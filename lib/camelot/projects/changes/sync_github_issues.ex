defmodule Camelot.Projects.Changes.SyncGithubIssues do
  @moduledoc """
  Ash generic action implementation that syncs GitHub issues
  labeled "camelot" into Camelot tasks.
  """
  use Ash.Resource.Actions.Implementation

  alias Camelot.Board.Task
  alias Camelot.Github.Client
  alias Camelot.Projects.Project

  require Logger

  @sync_label "camelot"

  @impl true
  @spec run(
          Ash.ActionInput.t(),
          keyword(),
          Ash.Resource.Actions.Implementation.Context.t()
        ) :: :ok
  def run(_input, _opts, _context) do
    Enum.each(projects_with_github(), &sync_project_issues/1)
    :ok
  end

  defp projects_with_github do
    Project
    |> Ash.read!()
    |> Enum.filter(fn p ->
      p.github_owner && p.github_repo
    end)
  end

  defp sync_project_issues(project) do
    case Client.list_issues(
           project.github_owner,
           project.github_repo,
           labels: @sync_label
         ) do
      {:ok, issues} ->
        Enum.each(issues, &maybe_create_task(project, &1))

      {:error, reason} ->
        Logger.warning(
          "Issue sync failed for #{project.name}: " <>
            "#{inspect(reason)}"
        )
    end
  end

  defp maybe_create_task(project, issue) do
    title = "GH##{issue["number"]}: #{issue["title"]}"

    existing =
      Task
      |> Ash.read!()
      |> Enum.find(&(&1.title == title))

    if !existing do
      case Ash.create(Task, %{
             title: title,
             description: issue["body"],
             project_id: project.id,
             creator_id: get_system_user_id()
           }) do
        {:ok, _task} ->
          Logger.info("Created task from issue ##{issue["number"]}")

        {:error, error} ->
          Logger.warning(
            "Failed to create task from issue: " <>
              "#{inspect(error)}"
          )
      end
    end
  end

  defp get_system_user_id do
    case Ash.read!(Camelot.Accounts.User) do
      [user | _] -> user.id
      [] -> raise "No users exist for issue sync"
    end
  end
end
