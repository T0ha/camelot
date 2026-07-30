defmodule Camelot.Telemetry.PostHogHandler do
  @moduledoc """
  Translates internal `:telemetry` events into PostHog captures.

  Listens for `[:camelot, :ash, :notify]` (emitted by
  `Camelot.Telemetry.Notifier` on every tracked resource) and
  `[:camelot, :user, :signed_in]` (emitted directly from
  `CamelotWeb.AuthController`). Only the curated actions in
  `@event_names` are forwarded to PostHog — everything else is
  ignored, keeping the notifier itself dumb.
  """

  @ash_notify_event [:camelot, :ash, :notify]
  @user_signed_in_event [:camelot, :user, :signed_in]

  @event_names %{
    {Camelot.Board.Task, :create} => "task_created",
    {Camelot.Board.Task, :begin_work} => "task_started",
    {Camelot.Board.Task, :submit_plan} => "task_plan_submitted",
    {Camelot.Board.Task, :approve_plan} => "task_plan_approved",
    {Camelot.Board.Task, :pr_created} => "task_pr_created",
    {Camelot.Board.Task, :complete} => "task_completed",
    {Camelot.Board.Task, :cancel} => "task_cancelled",
    {Camelot.Board.Task, :mark_error} => "task_errored",
    {Camelot.Projects.Project, :create} => "project_created",
    {Camelot.Agents.Agent, :create} => "agent_created"
  }

  @doc """
  Attaches this handler to the events it translates. Called once from
  `Camelot.Application.start/2`.
  """
  @spec attach() :: :ok
  def attach do
    :telemetry.attach_many(
      __MODULE__,
      [@ash_notify_event, @user_signed_in_event],
      &__MODULE__.handle_event/4,
      nil
    )

    :ok
  end

  @doc false
  @spec handle_event(:telemetry.event_name(), :telemetry.event_measurements(), map(), term()) :: :ok
  def handle_event(@ash_notify_event, _measurements, metadata, _config), do: handle_ash_notify(metadata)

  def handle_event(@user_signed_in_event, _measurements, metadata, _config), do: handle_user_signed_in(metadata)

  @spec handle_ash_notify(%{
          resource: Ash.Resource.t(),
          action: Ash.Resource.Actions.action(),
          actor: Ash.Resource.record() | nil,
          data: Ash.Resource.record()
        }) :: :ok
  defp handle_ash_notify(%{resource: resource, action: action, actor: actor, data: data}) do
    case Map.fetch(@event_names, {resource, action.name}) do
      {:ok, event} -> capture(event, distinct_id(data, actor), %{data_id: data.id})
      :error -> :ok
    end
  end

  @spec handle_user_signed_in(%{user: Ash.Resource.record()}) :: :ok
  defp handle_user_signed_in(%{user: user}) do
    capture("user_signed_in", user.id, %{
      "$set" => %{"email" => to_string(user.email), "role" => to_string(user.role)}
    })
  end

  @spec distinct_id(Ash.Resource.record(), Ash.Resource.record() | nil) :: String.t() | nil
  defp distinct_id(data, actor) do
    case {actor, data} do
      {%{id: actor_id}, _data} -> actor_id
      {_actor, %{creator_id: creator_id}} when is_binary(creator_id) -> creator_id
      {_actor, %{user_id: user_id}} when is_binary(user_id) -> user_id
      _no_distinct_id -> nil
    end
  end

  @spec capture(String.t(), String.t() | nil, PostHog.properties()) :: :ok
  defp capture(_event, nil, _properties), do: :ok

  defp capture(event, distinct_id, properties), do: PostHog.bare_capture(event, distinct_id, properties)
end
