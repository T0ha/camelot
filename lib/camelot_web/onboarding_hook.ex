defmodule CamelotWeb.OnboardingHook do
  @moduledoc """
  Puts the first-login setup guide in front of every
  authenticated LiveView.

  Runs after `CamelotWeb.LiveUserAuth`, which has already
  halted anyone who isn't signed in. Users who finished
  setup carry `onboarding_completed_at`, which short-circuits
  the hook before it assigns or queries anything — the guide
  costs settled accounts nothing.

  While setup is outstanding the hook attaches three hooks
  of its own so the strip stays honest: `:handle_params`
  recomputes on navigation, `:handle_info` recomputes on a
  `{:onboarding, :refresh}` nudge from the host LiveView,
  and `:handle_event` serves the guide's own buttons.

  The guide is also where the activation funnel is measured:
  every render, click and step completion is captured
  (`Camelot.Telemetry.Capture`), and each refresh restates
  the user's progress as PostHog person properties, so the
  "stuck at step X" cohort is a person-property filter
  rather than a join.
  """
  import Phoenix.Component
  import Phoenix.LiveView

  alias Camelot.Accounts.User
  alias Camelot.Telemetry.Capture
  alias CamelotWeb.Onboarding
  alias CamelotWeb.Onboarding.Status
  alias CamelotWeb.OnboardingComponents
  alias Phoenix.LiveView.Socket

  @spec on_mount(atom(), map(), map(), Socket.t()) :: {:cont, Socket.t()}
  def on_mount(:default, _params, _session, socket) do
    {:cont, install(socket, socket.assigns[:current_user])}
  end

  defp install(socket, %User{onboarding_completed_at: %DateTime{}}), do: socket

  defp install(socket, %User{} = user) do
    socket
    |> apply_status(user, Onboarding.status(user))
    |> attach_guide_hooks(user)
    |> capture_shown(user)
  end

  defp install(socket, _anonymous), do: socket

  # Dismissal only silences the auto-opening modal; the strip
  # carries progress from then on.
  defp attach_guide_hooks(%Socket{assigns: %{onboarding: %Status{}}} = socket, user) do
    socket
    |> assign(onboarding_modal?: is_nil(user.onboarding_dismissed_at))
    |> attach_hook(:onboarding_params, :handle_params, &refresh_on_params/3)
    |> attach_hook(:onboarding_event, :handle_event, &handle_event/3)
    |> attach_hook(:onboarding_info, :handle_info, &handle_info/2)
  end

  defp attach_guide_hooks(socket, _user), do: socket

  # Only on the connected mount: the dead render would double every
  # impression, and a disconnected client never saw the modal.
  defp capture_shown(%Socket{assigns: %{onboarding: %Status{} = status, onboarding_modal?: true}} = socket, user) do
    if connected?(socket) do
      capture(
        "onboarding_shown",
        user,
        Map.put(status_properties(status), "$set", person_properties(status))
      )
    else
      :ok
    end

    socket
  end

  defp capture_shown(socket, _user), do: socket

  # A user who arrives with everything already done — an
  # account that predates the guide, say — is stamped as
  # complete and never bothered again.
  defp apply_status(socket, user, %Status{complete?: true} = status) do
    set_guide_context(status)

    socket
    |> assign(current_user: Onboarding.mark_complete!(user))
    |> assign(onboarding: nil, onboarding_modal?: false)
  end

  defp apply_status(socket, _user, %Status{} = status) do
    assign(socket, onboarding: status)
  end

  defp refresh_on_params(_params, _uri, socket), do: {:cont, refresh(socket)}

  # The nudge is a broadcast, not a command addressed to this
  # hook: the host LiveView may well want to react to the same
  # message, so observe it and hand it on.
  defp handle_info({:onboarding, :refresh}, socket), do: {:cont, refresh(socket)}
  defp handle_info(_message, socket), do: {:cont, socket}

  defp handle_event("onboarding_dismiss", _params, socket) do
    {:halt, dismiss(socket)}
  end

  defp handle_event("onboarding_open", _params, socket) do
    {:halt, assign(socket, onboarding_modal?: true)}
  end

  # Persisting the dismissal server-side before pushing the
  # navigation keeps the two in a deterministic order.
  defp handle_event("onboarding_go", %{"step" => step}, socket) do
    {:halt, go_to_step(socket, step, OnboardingComponents.fetch_step_path(step))}
  end

  defp handle_event(_event, _params, socket), do: {:cont, socket}

  # `phx-value-step` arrives off the wire. Anything that isn't
  # a step we render is left alone rather than quietly sending
  # the user somewhere they didn't ask for — and is not
  # captured either, so the event's `step` property stays a
  # bounded enum.
  defp go_to_step(socket, step, {:ok, path}) do
    capture("onboarding_step_clicked", socket.assigns.current_user, %{step: step})

    push_navigate(dismiss(socket), to: path)
  end

  defp go_to_step(socket, _step, :error), do: socket

  defp dismiss(%Socket{assigns: %{onboarding: %Status{} = status}} = socket) do
    set_guide_context(status)

    socket
    |> assign(current_user: Onboarding.dismiss!(socket.assigns.current_user))
    |> assign(onboarding_modal?: false)
  end

  defp dismiss(socket) do
    socket
    |> assign(current_user: Onboarding.dismiss!(socket.assigns.current_user))
    |> assign(onboarding_modal?: false)
  end

  # Once the guide is done it stays done for the rest of the
  # session — no re-stamping `onboarding_completed_at` on
  # every subsequent navigation.
  defp refresh(%Socket{assigns: %{onboarding: nil}} = socket), do: socket

  defp refresh(%Socket{assigns: %{onboarding: %Status{} = status}} = socket) do
    user = socket.assigns.current_user
    refreshed = Onboarding.refresh(status, user)

    capture_completed_steps(user, status, refreshed)
    apply_status(socket, user, refreshed)
  end

  # One event per `false -> true` flip, so a step that was already
  # done before this session never inflates the funnel — and nothing
  # at all on the (overwhelmingly common) navigation that changes
  # nothing.
  defp capture_completed_steps(user, %Status{steps: before}, %Status{} = refreshed) do
    refreshed.steps
    |> Enum.filter(fn {step, done?} -> newly_done?(Keyword.get(before, step, true), done?) end)
    |> Enum.each(fn {step, _done?} ->
      capture("onboarding_step_completed", user, %{
        "$set" => person_properties(refreshed),
        step: to_string(step)
      })
    end)
  end

  defp newly_done?(false, true), do: true
  defp newly_done?(_before, _now), do: false

  @spec person_properties(Status.t()) :: map()
  defp person_properties(%Status{steps: steps} = status) do
    %{
      "onboarding_next_step" => to_string(status.next),
      "github_connected" => Keyword.get(steps, :github, false),
      "has_claude_token" => Keyword.get(steps, :claude_token, false),
      "has_project" => Keyword.get(steps, :project, false),
      "has_task" => Keyword.get(steps, :task, false)
    }
  end

  # `onboarding_dismissed` / `onboarding_completed` are captured from
  # the User resource's own notifier, which sees the user but not the
  # guide. The process context carries the missing half across.
  @spec set_guide_context(Status.t()) :: :ok
  defp set_guide_context(%Status{} = status) do
    PostHog.set_context(status_properties(status))
  end

  @spec status_properties(Status.t()) :: map()
  defp status_properties(%Status{} = status) do
    %{
      steps_total: Status.total_count(status),
      steps_done: Status.done_count(status),
      next_step: to_string(status.next)
    }
  end

  defp capture(event, user, properties), do: Capture.capture(event, user, properties)
end
