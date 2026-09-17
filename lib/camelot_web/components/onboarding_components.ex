defmodule CamelotWeb.OnboardingComponents do
  @moduledoc """
  The first-login setup guide: a one-shot welcome modal and
  the checklist strip that carries progress afterwards.

  This module owns everything presentational about the
  guide — step labels, hints, icons and the screen each step
  hands off to. `CamelotWeb.Onboarding` owns the facts.

  Both are plain function components: the events they emit
  are picked up by the hooks `CamelotWeb.OnboardingHook`
  attaches to the host LiveView.
  """
  use CamelotWeb, :html

  alias CamelotWeb.Onboarding.Status

  @labels [
    github: "Connect the GitHub App",
    claude_token: "Add a Claude token",
    project: "Create a project",
    task: "Create a task"
  ]

  @hints [
    github: """
    Lets Camelot read your repositories and push branches for you,
    without an SSH key or a pasted token.
    """,
    claude_token: """
    The API key your runners use to talk to Claude. It's encrypted at
    rest and only ever shipped to the cluster as a secret.
    """,
    project: """
    Point Camelot at a GitHub repository. Name and repository are all
    you need — everything else has a sensible default.
    """,
    task: """
    Describe what you want done and drop the card on the board. Camelot
    takes it from there.
    """
  ]

  @ctas [
    github: "Connect GitHub",
    claude_token: "Add token",
    project: "New project",
    task: "New task"
  ]

  @doc """
  Human label for a setup step.
  """
  @spec step_label(Status.step()) :: String.t()
  def step_label(step), do: Keyword.fetch!(@labels, step)

  @steps Keyword.keys(@labels)

  @doc """
  Screen a setup step hands off to.
  """
  @spec step_path(Status.step()) :: String.t()
  # The Connect button on /profile re-signs a short-lived
  # state token on render, so the strip links to the section
  # rather than carrying a token of its own.
  def step_path(:github), do: ~p"/profile#github-app"
  def step_path(:claude_token), do: ~p"/profile#credentials"
  def step_path(:project), do: ~p"/projects/new"
  def step_path(:task), do: ~p"/?onboarding=task"

  @doc """
  Resolves the wire form of a step name to its screen.

  `phx-value-step` comes back as a string the client controls,
  so anything that isn't one of the steps this module renders
  gets `:error` — never `String.to_atom/1`, and never a
  fallback destination the user didn't ask for.
  """
  @spec fetch_step_path(String.t()) :: {:ok, String.t()} | :error
  def fetch_step_path(step) do
    case Enum.find(@steps, &(to_string(&1) == step)) do
      nil -> :error
      found -> {:ok, step_path(found)}
    end
  end

  @doc """
  Greeting modal shown once, on the first authenticated page
  a brand new user lands on.

  Every exit path — the call to action, "I'll do this
  later", the close button and the backdrop — pushes
  `"onboarding_dismiss"`, so the dismissal is persisted
  server-side before anything navigates.
  """
  attr :onboarding, Status, required: true
  attr :show, :boolean, default: false

  def welcome_modal(assigns) do
    ~H"""
    <.modal
      id="onboarding-welcome-modal"
      show={@show}
      on_cancel={JS.push("onboarding_dismiss")}
    >
      <h3 class="text-lg font-bold">Welcome to Camelot 🏰</h3>

      <p class="mt-2 text-sm text-base-content/70">
        Camelot runs coding agents on your repositories and brings the
        work back as pull requests. Four short steps and your first
        task is on the board.
      </p>

      <ol class="steps steps-vertical my-4 w-full">
        <li
          :for={{step, done?} <- @onboarding.steps}
          id={"onboarding-modal-step-#{step}"}
          class={["step text-left", done? && "step-primary"]}
        >
          <div class="ml-2 py-1">
            <p class={["font-medium", done? && "text-base-content/50 line-through"]}>
              {step_label(step)}
            </p>
            <p class="text-xs text-base-content/60">{step_hint(step)}</p>
          </div>
        </li>
      </ol>

      <div class="modal-action">
        <button class="btn btn-ghost btn-sm" phx-click="onboarding_dismiss">
          I'll do this later
        </button>
        <button
          :if={@onboarding.next}
          class="btn btn-primary btn-sm"
          phx-click="onboarding_go"
          phx-value-step={@onboarding.next}
        >
          {step_cta(@onboarding.next)}
        </button>
      </div>
    </.modal>
    """
  end

  @doc """
  Compact progress strip kept in the app layout until every
  applicable step is done.
  """
  attr :onboarding, Status, required: true

  def setup_bar(assigns) do
    ~H"""
    <div
      id="onboarding-setup-bar"
      class="mx-auto mt-4 flex max-w-6xl flex-wrap items-center gap-2 rounded border border-base-300 bg-base-200 px-4 py-2 text-sm"
    >
      <span class="font-semibold">
        Setup {Status.done_count(@onboarding)} of {Status.total_count(@onboarding)}
      </span>

      <.step_badge :for={{step, done?} <- @onboarding.steps} step={step} done?={done?} />

      <button class="btn btn-ghost btn-xs ml-auto" phx-click="onboarding_open">
        Show guide
      </button>
    </div>
    """
  end

  # A finished step is shown as plain text, not a link: there
  # is nothing left to do there, and an inviting badge would
  # send the user back to a screen they're done with.
  attr :step, :atom, required: true
  attr :done?, :boolean, required: true

  defp step_badge(%{done?: true} = assigns) do
    ~H"""
    <span
      id={"onboarding-step-#{@step}-done"}
      class="badge badge-sm badge-success gap-1 opacity-60"
    >
      <.icon name={step_icon(true)} class="size-3" />
      <span class="line-through">{step_label(@step)}</span>
    </span>
    """
  end

  defp step_badge(assigns) do
    ~H"""
    <.link
      id={"onboarding-step-#{@step}-pending"}
      navigate={step_path(@step)}
      class="badge badge-sm badge-ghost gap-1"
    >
      <.icon name={step_icon(false)} class="size-3" />
      {step_label(@step)}
    </.link>
    """
  end

  @doc """
  Inline nudge for a screen that completes a step, rendered
  only while that step is still outstanding.
  """
  attr :onboarding, Status, default: nil
  attr :step, :atom, required: true
  slot :inner_block, required: true

  def step_hint_callout(assigns) do
    assigns = assign(assigns, pending?: pending?(assigns[:onboarding], assigns.step))

    ~H"""
    <div :if={@pending?} id={"onboarding-hint-#{@step}"} class="alert alert-info text-sm">
      <.icon name="hero-light-bulb" class="size-4" />
      <span>{render_slot(@inner_block)}</span>
    </div>
    """
  end

  defp pending?(%Status{} = status, step), do: Status.pending?(status, step)
  defp pending?(_absent, _step), do: false

  defp step_hint(step), do: Keyword.fetch!(@hints, step)

  defp step_cta(step), do: Keyword.fetch!(@ctas, step)

  defp step_icon(true), do: "hero-check-circle"
  defp step_icon(false), do: "hero-arrow-right-circle"
end
