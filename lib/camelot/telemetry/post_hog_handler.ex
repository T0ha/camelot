defmodule Camelot.Telemetry.PostHogHandler do
  @moduledoc """
  Translates internal `:telemetry` events into PostHog captures.

  Listens for `[:camelot, :ash, :notify]` (emitted by
  `Camelot.Telemetry.Notifier` on every tracked resource) and
  `[:camelot, :user, :signed_in]` (emitted directly from
  `CamelotWeb.AuthController`).

  This module owns transport and identity only: which actions are
  worth an event, and what each one carries, lives in
  `Camelot.Telemetry.Events`; merging global properties and dropping
  anonymous captures lives in `Camelot.Telemetry.Capture`.
  """

  alias Camelot.Accounts.User
  alias Camelot.Telemetry.Capture
  alias Camelot.Telemetry.Events

  @ash_notify_event [:camelot, :ash, :notify]
  @user_signed_in_event [:camelot, :user, :signed_in]

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
  @spec handle_event(:telemetry.event_name(), :telemetry.event_measurements(), map(), term()) ::
          :ok
  def handle_event(@ash_notify_event, _measurements, metadata, _config) do
    handle_ash_notify(metadata)
  end

  def handle_event(@user_signed_in_event, _measurements, metadata, _config) do
    handle_user_signed_in(metadata)
  end

  @spec handle_ash_notify(%{
          resource: Ash.Resource.t(),
          action: Ash.Resource.Actions.action(),
          actor: Ash.Resource.record() | nil,
          data: Ash.Resource.record()
        }) :: :ok
  defp handle_ash_notify(%{resource: resource, action: action, actor: actor, data: data}) do
    case Events.resolve(resource, action.name, data, actor) do
      {:ok, event, properties} -> Capture.capture(event, distinct_id(data, actor), properties)
      :skip -> :ok
    end
  end

  # `$set` overwrites on every sign-in, so it carries the facts that
  # can change; `$set_once` carries the signup time, which cannot.
  @spec handle_user_signed_in(%{user: Ash.Resource.record()}) :: :ok
  defp handle_user_signed_in(%{user: user} = metadata) do
    person = Map.put(Capture.person_properties(user), "auth_method", auth_method(metadata))

    Capture.capture("user_signed_in", user.id, %{
      "$set" => person,
      "$set_once" => %{"signed_up_at" => signed_up_at(user)}
    })
  end

  @spec auth_method(map()) :: String.t()
  defp auth_method(%{auth_method: auth_method}), do: to_string(auth_method)
  defp auth_method(_metadata), do: "unknown"

  @spec signed_up_at(Ash.Resource.record()) :: String.t() | nil
  defp signed_up_at(%{inserted_at: %DateTime{} = inserted_at}) do
    DateTime.to_iso8601(inserted_at)
  end

  defp signed_up_at(_user), do: nil

  @spec distinct_id(Ash.Resource.record(), Ash.Resource.record() | nil) :: String.t() | nil
  defp distinct_id(data, actor) do
    case {actor, data} do
      {%{id: actor_id}, _data} -> actor_id
      {_actor, %User{id: id}} -> id
      {_actor, %{creator_id: creator_id}} when is_binary(creator_id) -> creator_id
      {_actor, %{user_id: user_id}} when is_binary(user_id) -> user_id
      _no_distinct_id -> nil
    end
  end
end
