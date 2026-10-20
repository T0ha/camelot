defmodule Camelot.Projects.Changes.SyncGithubIssues do
  @moduledoc """
  Ash generic action implementation that syncs GitHub issues
  labeled "camelot" into Camelot tasks.

  An issue is imported once, keyed on `project_id` + `issue_number`,
  and only when the `camelot` label was applied by a member of the
  project (`Camelot.Github.IssueTrust`). Its directive labels
  (`Camelot.Github.IssueDirectives`) — likewise only when a member
  applied them — pick the agent, the model, and whether planning is
  skipped. An agent, model or credential problem is explained in an
  issue comment instead of creating a task, and the issue is labelled
  `camelot:invalid-config`; the next sync retries it. See
  `docs/github-issues-workflow.md`.
  """
  use Ash.Resource.Actions.Implementation

  alias Camelot.Accounts.UserCredentials
  alias Camelot.Agents.Agent
  alias Camelot.Agents.ModelDiscovery
  alias Camelot.Board.Task
  alias Camelot.Github.Client
  alias Camelot.Github.IssueAttachments
  alias Camelot.Github.IssueDirectives
  alias Camelot.Github.IssueTrust
  alias Camelot.Github.PullRequestApi
  alias Camelot.Github.Resolver
  alias Camelot.Projects.Project
  alias Camelot.Telemetry.Capture

  require Ash.Query
  require Logger

  @sync_label "camelot"
  @skip_plan_label "camelot:skip-plan"
  @invalid_config_label "camelot:invalid-config"

  @typedoc "What happened to one issue."
  @type import_result ::
          {:ok, Task.t()} | {:invalid, [String.t()]} | :untrusted | {:error, term()}

  @impl true
  @spec run(
          Ash.ActionInput.t(),
          keyword(),
          Ash.Resource.Actions.Implementation.Context.t()
        ) :: :ok
  def run(_input, _opts, _context) do
    Enum.each(syncable_projects(), &sync_project_issues/1)
    :ok
  end

  defp syncable_projects do
    Project
    |> Ash.read!(load: [owner_membership: [user: [:github_installations]]], authorize?: false)
    |> Enum.filter(&syncable?/1)
  end

  @doc """
  True when `project` should have its GitHub issues imported: it is
  active, points at a repository, and has an owner whose installation
  can be used to talk to GitHub.
  """
  @spec syncable?(Project.t()) :: boolean()
  def syncable?(%Project{github_owner: nil}), do: false
  def syncable?(%Project{github_repo: nil}), do: false
  def syncable?(%Project{owner_membership: nil}), do: false
  def syncable?(%Project{} = project), do: Project.active?(project)

  defp sync_project_issues(project) do
    case Client.list_issues(
           project.github_owner,
           project.github_repo,
           labels: @sync_label,
           installation_id: installation_id(project)
         ) do
      {:ok, issues} ->
        issues
        |> Enum.reject(&imported?(project, &1))
        |> Enum.each(&fetch_and_import(project, &1))

      {:error, reason} ->
        Logger.warning(
          "Issue sync failed for #{project.name}: " <>
            "#{inspect(reason)}"
        )
    end
  end

  @doc """
  True when `issue` already has a task in `project`.

  Matches on `issue_number`, falling back to the `GH#<n>: <title>`
  title match tasks imported before `issue_number` existed were
  de-duplicated by.
  """
  @spec imported?(Project.t(), map()) :: boolean()
  def imported?(project, %{"number" => number} = issue) do
    title = task_title(issue)

    Task
    |> Ash.Query.filter(project_id == ^project.id and (issue_number == ^number or title == ^title))
    |> Ash.exists?(authorize?: false)
  end

  defp fetch_and_import(project, issue) do
    opts = [installation_id: installation_id(project)]
    owner = project.github_owner
    repo = project.github_repo

    with {:ok, events} <- Client.list_issue_events(owner, repo, issue["number"], opts),
         {:ok, reactions} <- fetch_issue_reactions(project, issue, opts) do
      log_import(issue, import_issue(project, issue, events, reactions))
    else
      {:error, reason} ->
        Logger.warning("Issue sync failed for issue ##{issue["number"]}: #{inspect(reason)}")
    end
  end

  # The issue's reactions only matter for a stranger's issue asking to
  # skip planning, so every other issue is spared the extra call.
  defp fetch_issue_reactions(project, issue, opts) do
    issue
    |> label?(@skip_plan_label)
    |> issue_reactions(project, issue, opts)
  end

  defp issue_reactions(true, project, issue, opts) do
    Client.list_issue_reactions(project.github_owner, project.github_repo, issue["number"], opts)
  end

  defp issue_reactions(false, _project, _issue, _opts), do: {:ok, []}

  defp log_import(issue, {:ok, _task}), do: Logger.info("Created task from issue ##{issue["number"]}")

  defp log_import(issue, {:invalid, problems}) do
    Logger.info("Issue ##{issue["number"]} not imported: #{Enum.join(problems, " ")}")
  end

  defp log_import(issue, :untrusted) do
    Logger.debug("Issue ##{issue["number"]} not imported: camelot label not applied by a project member")
  end

  defp log_import(issue, {:error, error}) do
    Logger.warning("Failed to create task from issue ##{issue["number"]}: #{inspect(error)}")
  end

  @doc """
  Imports one not-yet-imported `issue` into `project`, given the
  issue's `events` (for who applied which label) and its `reactions`
  (for an owner vouching for a stranger's issue).

  `project` must have `owner_membership: [user: [:github_installations]]`
  loaded; the owner becomes the task's creator, so the owner's
  credentials are what the agent and model are checked against.
  """
  @spec import_issue(Project.t(), map(), [map()], [map()]) :: import_result()
  def import_issue(project, issue, events, reactions) do
    project
    |> labeled_by_trusted?(@sync_label, events)
    |> import_attached(project, issue, events, reactions)
  end

  defp import_attached(false, _project, _issue, _events, _reactions), do: :untrusted

  defp import_attached(true, project, issue, events, reactions) do
    directives = trusted_directives(project, issue, events)
    creator = project.owner_membership.user

    case resolve_config(directives, creator) do
      {:ok, agent} ->
        skip_planning? = skip_planning?(project, issue, directives, reactions)
        create_task(project, issue, agent, directives.model, skip_planning?)

      {:invalid, problems} ->
        report_invalid(project, issue, problems)
    end
  end

  # Only directive labels a member applied count; a stranger adding
  # `camelot:agent:…` to someone else's issue changes nothing.
  defp trusted_directives(project, issue, events) do
    (issue["labels"] || [])
    |> IssueDirectives.label_names()
    |> Enum.filter(&(IssueDirectives.directive?(&1) and labeled_by_trusted?(project, &1, events)))
    |> IssueDirectives.parse()
  end

  # The latest `labeled` event for `label` decides, so re-applying a
  # label after a stranger did is how a member takes it over.
  defp labeled_by_trusted?(project, label, events) do
    events
    |> Enum.filter(&(&1["event"] == "labeled" and get_in(&1, ["label", "name"]) == label))
    |> List.last()
    |> trusted_event?(project)
  end

  defp trusted_event?(nil, _project), do: false
  defp trusted_event?(event, project), do: IssueTrust.trusted?(IssueTrust.actor_id(event), project.id)

  # A stranger's issue body becomes the plan only once an owner has
  # 👍-ed the issue. Issue edits cannot be told apart from label changes
  # through the REST API (both bump `updated_at`), so unlike comments
  # the 👍 is not voided by later activity — see the docs' caveats.
  defp skip_planning?(_project, _issue, %{skip_planning?: false}, _reactions), do: false
  defp skip_planning?(_project, %{"body" => nil}, _directives, _reactions), do: false
  defp skip_planning?(_project, %{"body" => ""}, _directives, _reactions), do: false

  defp skip_planning?(project, issue, _directives, reactions) do
    IssueTrust.trusted?(IssueTrust.actor_id(issue), project.id) or
      IssueTrust.owner_approved?(%{}, reactions, project.id)
  end

  @doc """
  Resolves the directives to an agent the creator can run, or the
  problems that stop it, worded for the issue comment.
  """
  @spec resolve_config(IssueDirectives.t(), Camelot.Accounts.User.t()) ::
          {:ok, Agent.t()} | {:invalid, [String.t()]}
  def resolve_config(directives, creator) do
    with {:ok, agent} <- resolve_agent(directives.agent_slug),
         :ok <- check_model(agent, directives.model, creator),
         :ok <- check_credentials(agent, creator) do
      {:ok, agent}
    end
  end

  defp resolve_agent(nil) do
    case default_agent() do
      nil -> {:invalid, ["No Agent CLI is configured in Camelot yet."]}
      agent -> {:ok, agent}
    end
  end

  defp resolve_agent(slug) do
    case Camelot.Agents.get_agent_by_slug(slug, authorize?: false) do
      {:ok, agent} ->
        {:ok, agent}

      {:error, _not_found} ->
        {:invalid, ["Unknown agent `#{slug}`. Valid agent slugs: #{code_list(agent_slugs())}."]}
    end
  end

  # The same set the task form offers and `Task`'s own `next_model`
  # validation checks against; an agent with no models imposes none.
  defp check_model(_agent, nil, _creator), do: :ok

  defp check_model(agent, model, creator) do
    agent
    |> ModelDiscovery.models_for(creator.id)
    |> model_problem(agent, model)
  end

  defp model_problem([], _agent, _model), do: :ok

  defp model_problem(models, agent, model) do
    models
    |> Enum.member?(model)
    |> model_allowed(models, agent, model)
  end

  defp model_allowed(true, _models, _agent, _model), do: :ok

  defp model_allowed(false, models, agent, model) do
    {:invalid,
     [
       "Model `#{model}` is not available for agent `#{agent.slug}`. " <>
         "Valid model ids: #{code_list(models)}."
     ]}
  end

  defp check_credentials(agent, creator) do
    creator
    |> UserCredentials.held_kinds()
    |> UserCredentials.missing_kinds(agent)
    |> credentials_problem(agent)
  end

  defp credentials_problem([], _agent), do: :ok

  defp credentials_problem(missing, agent) do
    {:invalid,
     [
       "The project owner has not added the credentials agent " <>
         "`#{agent.slug}` needs: #{code_list(missing)}. Add them on " <>
         "the Camelot profile page."
     ]}
  end

  defp create_task(project, issue, agent, model, skip_planning?) do
    case Ash.create(
           Task,
           %{
             title: task_title(issue),
             description: issue["body"],
             project_id: project.id,
             creator_id: project.owner_membership.user.id,
             agent_id: agent.id,
             next_model: model,
             issue_number: issue["number"],
             skip_planning: skip_planning?
           },
           authorize?: false
         ) do
      {:ok, task} ->
        IssueAttachments.import_from_issue!(task, issue["body"])
        clear_invalid_config(project, issue)
        capture_attached(task, model, skip_planning?)
        {:ok, task}

      {:error, error} ->
        {:error, error}
    end
  end

  defp task_title(issue), do: "GH##{issue["number"]}: #{issue["title"]}"

  defp capture_attached(task, model, skip_planning?) do
    Capture.capture("issue_attached", task.creator_id, %{
      data_id: task.id,
      has_model_label: not is_nil(model),
      skip_planning: skip_planning?
    })
  end

  # Commented once: while the issue still carries the label, a retry
  # that fails again stays quiet instead of commenting every 5 minutes.
  defp report_invalid(project, issue, problems) do
    issue
    |> label?(@invalid_config_label)
    |> post_invalid_config(project, issue, problems)

    {:invalid, problems}
  end

  defp post_invalid_config(true, _project, _issue, _problems), do: :ok

  defp post_invalid_config(false, project, issue, problems) do
    api = PullRequestApi.impl()
    opts = [installation_id: installation_id(project)]
    owner = project.github_owner
    repo = project.github_repo
    number = issue["number"]

    with {:ok, _comment} <- api.create_issue_comment(owner, repo, number, invalid_config_body(problems), opts),
         {:ok, _labels} <- api.add_issue_labels(owner, repo, number, [@invalid_config_label], opts) do
      :ok
    else
      {:error, reason} ->
        Logger.warning("Could not report invalid config on issue ##{number}: #{inspect(reason)}")
    end
  end

  defp invalid_config_body(problems) do
    """
    <!-- camelot:invalid-config -->
    Camelot could not pick this issue up:

    #{Enum.map_join(problems, "\n", &"- #{&1}")}

    Fix the `camelot:agent:<slug>` / `camelot:model:<id>` labels (or the \
    credentials) and remove the `#{@invalid_config_label}` label; the \
    issue is retried on the next sync.
    """
  end

  defp clear_invalid_config(project, issue) do
    issue
    |> label?(@invalid_config_label)
    |> remove_invalid_config(project, issue)
  end

  defp remove_invalid_config(true, project, issue) do
    PullRequestApi.impl().remove_issue_label(
      project.github_owner,
      project.github_repo,
      issue["number"],
      @invalid_config_label,
      installation_id: installation_id(project)
    )
  end

  defp remove_invalid_config(false, _project, _issue), do: :ok

  defp label?(issue, label) do
    label in IssueDirectives.label_names(issue["labels"] || [])
  end

  defp code_list(values), do: Enum.map_join(values, ", ", &"`#{&1}`")

  defp agent_slugs do
    Agent
    |> Ash.Query.sort(:slug)
    |> Ash.read!(authorize?: false)
    |> Enum.map(& &1.slug)
  end

  # GitHub-issue-synced tasks have no user present to pick a CLI
  # agent, so unless a `camelot:agent:<slug>` label names one a
  # pragmatic default is used: the first Agent CLI alphabetically by
  # slug.
  defp default_agent do
    Agent
    |> Ash.Query.sort(:slug)
    |> Ash.Query.limit(1)
    |> Ash.read_one!(authorize?: false)
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
