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

  require Logger

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
    safely(fn -> handle_ash_notify(metadata) end)
  end

  def handle_event(@user_signed_in_event, _measurements, metadata, _config) do
    safely(fn -> handle_user_signed_in(metadata) end)
  end

  # `:telemetry` detaches a handler that raises, and it does so
  # globally and permanently: one bad notification would take the
  # whole product funnel offline until the node restarts, silently.
  # Enriching an event now reads the database (`Events.resolve/4`), so
  # that is no longer a theoretical risk — analytics must fail closed
  # on the single event, never on the handler.
  @spec safely((-> :ok)) :: :ok
  defp safely(fun) do
    fun.()
  rescue
    error ->
      Logger.warning("PostHog capture failed", reason: error.__struct__)

      :ok
  catch
    :exit, _reason -> :ok
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
  @spec handle_user_signed_in(%{
          :user => User.t(),
          optional(:auth_method) => :github | :magic_link
        }) :: :ok
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

  @spec signed_up_at(User.t()) :: String.t() | nil
  defp signed_up_at(%{inserted_at: %DateTime{} = inserted_at}) do
    DateTime.to_iso8601(inserted_at)
  end

  defp signed_up_at(_user), do: nil

  # A notification whose subject *is* a user is about that user, not
  # about whoever ran the action. Both `:create_user` call sites pass
  # the inviter as the actor — the admin screen and a project invite
  # — so crediting them would drop the invited account out of the
  # funnel's first step for good (a returning login is an upsert and
  # never re-emits `user_signed_up`) and count the inviter as signing
  # up once per invite.
  @spec distinct_id(Ash.Resource.record(), Ash.Resource.record() | nil) :: String.t() | nil
  defp distinct_id(%User{id: id}, _actor), do: id

  defp distinct_id(data, actor) do
    case {actor, data} do
      {%{id: actor_id}, _data} -> actor_id
      {_actor, %{creator_id: creator_id}} when is_binary(creator_id) -> creator_id
      {_actor, %{user_id: user_id}} when is_binary(user_id) -> user_id
      _no_distinct_id -> nil
    end
  end
end
