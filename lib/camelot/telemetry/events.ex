defmodule Camelot.Telemetry.Events do
  @moduledoc """
  The catalogue of Ash actions worth reporting to PostHog, and the
  properties each one carries.

  `Camelot.Telemetry.Notifier` fires for *every* notification on the
  resources that register it; this module is the curation step, so the
  notifier stays dumb and the handler stays about transport. Pure
  functions over `{resource, action, data, actor}` — no capture, no
  process state — which is what makes the funnel's shape testable
  without a PostHog in the loop.

  Every property here is bounded: enums, booleans, ids and counts. No
  `inspect/1` output, no user-supplied text, and never a credential
  value.
  """

  alias Camelot.Accounts.Credential
  alias Camelot.Accounts.User
  alias Camelot.Agents.Agent
  alias Camelot.Board.Task
  alias Camelot.Github.Installation
  alias Camelot.Projects.Project
  alias Camelot.Telemetry.TaskFailure

  require Ash.Query

  @typedoc "A resolved capture: the event name and its properties."
  @type resolved :: {:ok, String.t(), map()}

  @event_names %{
    {Task, :create} => "task_created",
    {Task, :begin_work} => "task_started",
    {Task, :submit_plan} => "task_plan_submitted",
    {Task, :approve_plan} => "task_plan_approved",
    {Task, :pr_created} => "task_pr_created",
    {Task, :complete} => "task_completed",
    {Task, :cancel} => "task_cancelled",
    {Task, :mark_error} => "task_errored",
    {Task, :mark_runner_lost} => "task_runner_lost",
    {Project, :create} => "project_created",
    {User, :create_user} => "user_signed_up",
    {User, :register_with_github} => "user_signed_up",
    {User, :sign_in_with_magic_link} => "user_signed_up",
    {User, :dismiss_onboarding} => "onboarding_dismissed",
    {User, :complete_onboarding} => "onboarding_completed",
    {Credential, :create} => "credential_added",
    {Credential, :destroy} => "credential_removed",
    {Installation, :link_user} => "github_installation_linked",
    {Installation, :suspend} => "github_installation_suspended",
    {Installation, :unsuspend} => "github_installation_unsuspended",
    {Agent, :create} => "agent_created",
    {Agent, :update} => "agent_updated"
  }

  # Both `:register_with_github` and `:sign_in_with_magic_link` are
  # upserts, so they notify as creates on *every* login. Ash exposes no
  # insert-vs-conflict flag, and `inserted_at` is not in the resources'
  # `upsert_fields`, so a returning user still carries their original
  # signup time — a fresh `inserted_at` is the reliable signal that
  # this login actually made the account.
  @signup_window_s 60

  @auth_methods %{
    register_with_github: "github",
    sign_in_with_magic_link: "magic_link",
    create_user: "invite"
  }

  @doc "Every action this module reports, keyed by `{resource, action}`."
  @spec event_names() :: %{{module(), atom()} => String.t()}
  def event_names, do: @event_names

  @doc """
  Resolves an Ash notification into the event to capture, or `:skip`
  when this action isn't part of the catalogue (or is one the
  catalogue deliberately ignores, like the SSH key the server writes
  for every new account).
  """
  @spec resolve(module(), atom(), struct(), struct() | nil) :: resolved() | :skip
  def resolve(resource, action, data, actor) do
    case Map.fetch(@event_names, {resource, action}) do
      {:ok, event} -> build(event, action, data, actor)
      :error -> :skip
    end
  end

  @spec build(String.t(), atom(), struct(), struct() | nil) :: resolved() | :skip
  defp build("user_signed_up", action, %User{} = user, _actor) do
    if new_user?(user) do
      {:ok, "user_signed_up", signup_properties(action, user)}
    else
      :skip
    end
  end

  defp build("onboarding_completed", _action, %User{} = user, _actor) do
    {:ok, "onboarding_completed", %{data_id: user.id, duration_since_signup_s: seconds_since(user.inserted_at)}}
  end

  defp build("credential_added", _action, %Credential{} = credential, _actor) do
    credential_event(credential, "claude_token_added", "credential_added")
  end

  defp build("credential_removed", _action, %Credential{} = credential, _actor) do
    credential_event(credential, "claude_token_removed", "credential_removed")
  end

  defp build("project_created", _action, %Project{} = project, actor) do
    {:ok, "project_created",
     %{
       data_id: project.id,
       has_github_repo: not is_nil(project.github_repo),
       has_github_installation: github_installation?(actor)
     }}
  end

  defp build("task_errored", _action, %Task{} = task, _actor) do
    {stage, reason} = TaskFailure.classify(task)

    {:ok, "task_errored", %{data_id: task.id, stage: stage, reason: reason}}
  end

  defp build("task_runner_lost", _action, %Task{} = task, _actor) do
    {stage, reason} = TaskFailure.classify(task)

    {:ok, "task_runner_lost", %{data_id: task.id, stage: stage, reason: reason}}
  end

  defp build(event, _action, %Installation{} = installation, _actor) do
    {:ok, event, %{data_id: installation.id, installation_id: installation.installation_id}}
  end

  defp build(event, _action, %Agent{} = agent, _actor) do
    {:ok, event, %{data_id: agent.id, slug: agent.slug}}
  end

  defp build(event, _action, data, _actor), do: {:ok, event, %{data_id: data.id}}

  @spec signup_properties(atom(), User.t()) :: map()
  defp signup_properties(action, user) do
    %{
      data_id: user.id,
      auth_method: Map.get(@auth_methods, action, "unknown")
    }
  end

  # The default SSH key is written by
  # `Camelot.Accounts.User.Changes.EnsureDefaultSshKey` on every
  # signup, so counting it as a credential the user added would put a
  # 100% conversion step in the middle of the funnel.
  @spec credential_event(Credential.t(), String.t(), String.t()) :: resolved() | :skip
  defp credential_event(%Credential{metadata: %{"source" => "server_generated"}}, _claude, _other) do
    :skip
  end

  defp credential_event(%Credential{kind: :claude_api_key} = credential, claude_event, _other) do
    {:ok, claude_event, %{data_id: credential.id, kind: to_string(credential.kind)}}
  end

  defp credential_event(%Credential{} = credential, _claude_event, other_event) do
    {:ok, other_event, %{data_id: credential.id, kind: to_string(credential.kind)}}
  end

  @spec new_user?(User.t()) :: boolean()
  defp new_user?(%User{inserted_at: %DateTime{} = inserted_at}) do
    seconds_since(inserted_at) < @signup_window_s
  end

  defp new_user?(_user), do: false

  @spec seconds_since(DateTime.t() | nil) :: integer()
  defp seconds_since(%DateTime{} = moment), do: DateTime.diff(DateTime.utc_now(), moment)
  defp seconds_since(_no_moment), do: 0

  # One cheap existence check rather than loading the actor's
  # installations: `project_created` is low volume, and knowing whether
  # the creator had the GitHub App connected is what separates "made a
  # project" from "made a project that can actually run".
  @spec github_installation?(struct() | nil) :: boolean()
  defp github_installation?(%{id: user_id}) do
    Installation
    |> Ash.Query.filter(user_id == ^user_id and is_nil(suspended_at))
    |> Ash.exists?(authorize?: false)
  end

  defp github_installation?(_no_actor), do: false
end
