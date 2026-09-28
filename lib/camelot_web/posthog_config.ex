defmodule CamelotWeb.PostHogConfig do
  @moduledoc """
  Builds the browser-side PostHog configuration exposed to
  `root.html.heex` via `data-*` attributes.

  Reuses the same `:posthog, :enable` / `:api_key` / `:api_host`
  application env that the server-side integration
  (`Camelot.Telemetry.PostHogHandler`) already relies on, and the same
  `distinct_id` convention (`user.id`), so frontend and backend events
  merge onto the same person.

  `environment` and `is_internal` come from
  `Camelot.Telemetry.Context`, the same source the server captures
  use, and are registered as browser super-properties — which is what
  puts them on autocaptured events (`$pageview`, `$exception`) that no
  server code ever sees.
  """

  alias Camelot.Telemetry.Context

  @type t :: %{
          api_key: String.t(),
          api_host: String.t() | nil,
          distinct_id: String.t() | nil,
          email: String.t() | nil,
          environment: String.t(),
          is_internal: String.t()
        }

  @doc """
  Whether PostHog capture is enabled, per the same `:posthog, :enable`
  flag the backend integration uses.
  """
  @spec enabled?() :: boolean()
  def enabled?, do: Application.get_env(:posthog, :enable, false)

  @doc """
  Builds the browser config for the given LiveView/conn assigns, or
  `nil` when PostHog is disabled.
  """
  @spec for(map()) :: t() | nil
  def for(assigns) do
    if enabled?() do
      build(assigns)
    end
  end

  @spec build(map()) :: t()
  defp build(assigns) do
    user = assigns[:current_user]

    %{
      api_key: Application.get_env(:posthog, :api_key),
      api_host: Application.get_env(:posthog, :api_host),
      distinct_id: distinct_id(user),
      email: email(user),
      environment: Context.environment(),
      is_internal: to_string(Context.internal?(user))
    }
  end

  @spec distinct_id(Ash.Resource.record() | nil) :: String.t() | nil
  defp distinct_id(%{id: id}), do: id
  defp distinct_id(_no_user), do: nil

  @spec email(Ash.Resource.record() | nil) :: String.t() | nil
  defp email(%{email: email}), do: to_string(email)
  defp email(_no_user), do: nil
end
