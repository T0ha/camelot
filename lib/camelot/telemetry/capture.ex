defmodule Camelot.Telemetry.Capture do
  @moduledoc """
  The one way this application sends a product event to PostHog.

  Everything that captures — the Ash notifier handler
  (`Camelot.Telemetry.PostHogHandler`), controllers and LiveViews —
  goes through here, so the global properties
  (`Camelot.Telemetry.Context.global_properties/0`) and the process's
  own `PostHog` context are merged in exactly once, and a capture with
  no `distinct_id` is dropped rather than creating an anonymous person.

  Precedence, lowest to highest: process context, global properties,
  the caller's explicit properties.
  """

  alias Camelot.Accounts.User
  alias Camelot.Telemetry.Context

  @typedoc """
  A person a capture can be attributed to: the user record itself, a
  bare distinct id, or nothing at all.

  A struct is spelled out rather than written as `%{id: String.t()}`
  because a bare map type in a spec is a *closed* one — it would
  exclude every struct, which is all this is ever called with.
  """
  @type subject :: User.t() | String.t() | nil

  @doc """
  Captures `event` for `subject`, or does nothing when the subject
  resolves to no `distinct_id`.
  """
  @spec capture(String.t(), subject(), map()) :: :ok
  def capture(event, subject, properties \\ %{})

  def capture(_event, nil, _properties), do: :ok
  def capture(event, %{id: id}, properties), do: capture(event, id, properties)

  def capture(event, distinct_id, properties) do
    PostHog.get_context()
    |> Map.merge(Context.global_properties())
    |> Map.merge(properties)
    |> then(&PostHog.bare_capture(event, distinct_id, &1))

    :ok
  end

  @doc """
  Person properties (`$set`) every signed-in capture can attach so
  cohorts need no joins back to the database.
  """
  @spec person_properties(User.t()) :: map()
  def person_properties(%{email: email} = user) do
    %{
      "email" => to_string(email),
      "role" => to_string(Map.get(user, :role)),
      "is_internal" => Context.internal?(user)
    }
  end
end
