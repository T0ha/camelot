defmodule Camelot.Projects.Changes.SyncGithubIssues do
  @moduledoc """
  Ash generic action implementation that syncs GitHub issues
  labeled "camelot" into Camelot tasks.
  """
  use Ash.Resource.Actions.Implementation

  alias Camelot.Board.Task
  alias Camelot.Github.Client
  alias Camelot.Github.IssueAttachments
  alias Camelot.Github.Resolver
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
    |> Ash.read!(load: [owner_membership: [user: [:github_installations]]], authorize?: false)
    |> Enum.filter(fn p ->
      p.github_owner && p.github_repo && p.owner_membership
    end)
  end

  defp sync_project_issues(project) do
    case Client.list_issues(
           project.github_owner,
           project.github_repo,
           labels: @sync_label,
           installation_id: installation_id(project)
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
             creator_id: project.owner_membership.user.id
           }) do
        {:ok, task} ->
          IssueAttachments.import_from_issue!(task, issue["body"])
          Logger.info("Created task from issue ##{issue["number"]}")

        {:error, error} ->
          Logger.warning(
            "Failed to create task from issue: " <>
              "#{inspect(error)}"
          )
      end
    end
  end

  @doc """
  Resolves the GitHub App installation id from the
  project owner's connected installation, if any.
  """
  @spec installation_id(Project.t()) :: integer() | nil
  def installation_id(%{owner_membership: %{user: %{github_installations: installations}}} = project) do
    Resolver.installation_id(installations, project.github_owner)
  end

  def installation_id(_project), do: nil
end
