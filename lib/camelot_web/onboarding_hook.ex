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
    |> report_progress(user)
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
  # impression, and a disconnected client never saw the guide.
  defp report_progress(%Socket{assigns: %{onboarding: %Status{} = status}} = socket, user) do
    if connected?(socket) do
      capture_progress(socket.assigns.onboarding_modal?, status, user)
    else
      :ok
    end

    socket
  end

  defp report_progress(socket, _user), do: socket

  # The person properties are the whole basis of the "stuck at step X"
  # cohort, so they have to keep up with a user who is moving — and
  # the modal is not a reliable moment to restate them. Clicking a
  # step dismisses the guide, after which it never auto-opens again,
  # and three of the four steps finish across a navigation or a full
  # page redirect, where `refresh/1` recomputes from scratch and has
  # no `false -> true` flip left to see. Left on the impression alone,
  # the cohort would show everyone who engaged with the guide stuck at
  # a step they had already finished.
  #
  # A strip-only render is not an impression, so it restates the
  # person and nothing else: `$set` is PostHog's own person-update
  # event and carries no product meaning, which keeps it out of every
  # funnel built on the events around it.
  @spec capture_progress(boolean(), Status.t(), User.t()) :: :ok
  defp capture_progress(true, status, user) do
    capture(
      "onboarding_shown",
      user,
      Map.put(status_properties(status), "$set", person_properties(status))
    )
  end

  defp capture_progress(false, status, user) do
    capture("$set", user, %{"$set" => person_properties(status)})
  end

  # A user who arrives with everything already done — an
  # account that predates the guide, say — is stamped as
  # complete and never bothered again.
  defp apply_status(socket, user, %Status{complete?: true} = status) do
    set_guide_context("onboarding_completed", status, %{})

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
    {:halt, dismiss(socket, "close")}
  end

  # Re-opening the guide from the strip puts it back in front of the
  # user, so it is an impression like any other — and the only one a
  # dismissed guide can still produce.
  defp handle_event("onboarding_open", _params, %Socket{assigns: %{onboarding: %Status{} = status}} = socket) do
    capture_progress(true, status, socket.assigns.current_user)

    {:halt, assign(socket, onboarding_modal?: true)}
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

    push_navigate(dismiss(socket, "step_click"), to: path)
  end

  defp go_to_step(socket, _step, :error), do: socket

  # Clicking a step dismisses the guide too, so without `via` the
  # "gave up" event and the most engaged action the guide offers
  # would be indistinguishable — and `onboarding_dismissed` would
  # measure engagement rather than abandonment.
  @spec dismiss(Socket.t(), String.t()) :: Socket.t()
  defp dismiss(%Socket{assigns: %{onboarding: %Status{} = status}} = socket, via) do
    set_guide_context("onboarding_dismissed", status, %{via: via})

    forget_guide(socket)
  end

  defp dismiss(socket, via) do
    PostHog.set_event_context("onboarding_dismissed", %{via: via})

    forget_guide(socket)
  end

  @spec forget_guide(Socket.t()) :: Socket.t()
  defp forget_guide(socket) do
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
  #
  # Scoped to the one event rather than the whole process:
  # `PostHog.Context` only ever merges and cannot delete, so a
  # process-wide write would stamp this guide's `steps_done` onto
  # every later capture from the same LiveView — `project_created`,
  # `task_form_blocked` — at whatever value it held here.
  @spec set_guide_context(String.t(), Status.t(), map()) :: :ok
  defp set_guide_context(event, %Status{} = status, extra) do
    PostHog.set_event_context(event, Map.merge(status_properties(status), extra))
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
