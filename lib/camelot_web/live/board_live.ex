defmodule CamelotWeb.BoardLive do
  @moduledoc """
  Kanban board LiveView — main page of the application.
  Displays tasks organized by stage columns with
  real-time PubSub updates.
  """
  use CamelotWeb, :live_view

  import CamelotWeb.BoardComponents

  alias AshPhoenix.Form
  alias Camelot.Accounts.UserCredentials
  alias Camelot.Agents.Agent
  alias Camelot.Agents.ModelDiscovery
  alias Camelot.Agents.ModelLabel
  alias Camelot.Board.Task
  alias Camelot.Board.TaskLink
  alias Camelot.Projects.Project
  alias Camelot.Telemetry.Capture
  alias CamelotWeb.Components.TaskPicker
  alias CamelotWeb.Scope
  alias CamelotWeb.TaskAttachments
  alias Phoenix.LiveView.Socket

  require Ash.Query
  require Logger

  @impl true
  @spec mount(map(), map(), Socket.t()) ::
          {:ok, Socket.t()}
  def mount(params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Camelot.PubSub, "board")
    end

    socket =
      socket
      |> assign(
        see_all: params["scope"] == "all",
        # The setup guide's last step links here with the New
        # Task modal already open.
        new_task_open?: params["onboarding"] == "task",
        parent_task: nil,
        blocked_by_task: nil,
        form_blocked_reported?: false
      )
      |> load_board()
      |> allow_upload(:attachment, accept: :any, max_entries: 5, max_file_size: 25_000_000)

    {:ok, gate(socket)}
  end

  # A board with no project is empty by construction and its New Task
  # form can never be submitted — PostHog's dead clicks cluster on
  # exactly that modal's empty selects. Send the user where the work
  # starts rather than render a form they cannot use.
  #
  # Reads the board's own project list rather than
  # `CamelotWeb.Onboarding.Status`, so an account that finished (or
  # predates) the guide is held to the same prerequisite.
  @spec gate(Socket.t()) :: Socket.t()
  defp gate(%Socket{assigns: %{projects: []}} = socket) do
    socket
    |> capture_form_blocked()
    |> put_flash(
      :info,
      "Create a project first — a task runs an agent against a project."
    )
    |> push_navigate(to: ~p"/projects")
  end

  # The setup guide's last step lands here with the modal already
  # open, which is precisely the case where it may have nothing
  # pickable in it. Only on the connected mount: the dead render would
  # double-count, and the project gate above redirects before it.
  defp gate(%Socket{assigns: %{new_task_open?: true}} = socket) do
    if connected?(socket) do
      capture_form_blocked(socket)
    else
      socket
    end
  end

  defp gate(socket), do: socket

  # Picker-backed link fields held outside the AshPhoenix create form.
  @picker_fields [:parent_task, :blocked_by_task]

  @impl true
  def handle_info({:task_updated, _task}, socket) do
    {:noreply, load_board(socket)}
  end

  def handle_info({:task_created, _task}, socket) do
    {:noreply, socket}
  end

  def handle_info({:task_selected, field, task}, socket) when field in @picker_fields do
    {:noreply, assign(socket, field, task)}
  end

  def handle_info({:task_cleared, field}, socket) when field in @picker_fields do
    {:noreply, assign(socket, field, nil)}
  end

  # Never crash the board on an unexpected PubSub message.
  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def handle_event("open_new_task", _params, socket) do
    {:noreply, socket |> capture_form_blocked() |> open_new_task()}
  end

  def handle_event("close_new_task", _params, socket) do
    {:noreply, assign(socket, new_task_open?: false)}
  end

  def handle_event("validate_task", %{"task" => params}, socket) do
    socket = assign(socket, task_form: Form.validate(socket.assigns.task_form, params))

    {:noreply, assign_model_options(socket)}
  end

  def handle_event("create_task", %{"task" => params}, socket) do
    agent = Enum.find(socket.assigns.agents, &(&1.id == params["agent_id"]))
    missing = UserCredentials.missing_kinds(socket.assigns.credential_kinds, agent)

    submit_task(socket, params, agent, missing)
  end

  def handle_event("cancel_task", %{"id" => id}, socket) do
    task = Ash.get!(Task, id)

    case Ash.update(task, %{}, action: :cancel) do
      {:ok, task} ->
        broadcast_task_event(:task_updated, task)
        {:noreply, load_board(socket)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Cannot cancel task")}
    end
  end

  def handle_event("toggle_scope", _params, socket) do
    {:noreply, socket |> assign(see_all: !socket.assigns.see_all) |> load_board()}
  end

  def handle_event("restart_task", %{"id" => id}, socket) do
    task = Ash.get!(Task, id)

    case Ash.update(task, %{}, action: :reset) do
      {:ok, task} ->
        broadcast_task_event(:task_updated, task)
        {:noreply, socket |> put_flash(:info, "Task restarted") |> load_board()}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Cannot restart task")}
    end
  end

  # A board left open while its last project is deleted elsewhere (or
  # the user's membership revoked) must not reopen a form a fresh
  # mount would have redirected away from, however stale the DOM that
  # pushed the event.
  @spec open_new_task(Socket.t()) :: Socket.t()
  defp open_new_task(%Socket{assigns: %{projects: []}} = socket), do: socket

  defp open_new_task(socket) do
    socket
    |> assign(new_task_open?: true)
    |> assign_model_options()
  end

  # Which models the picked agent CLI will actually accept is resolved
  # live, per user (`Camelot.Agents.ModelDiscovery`), so it is I/O —
  # hence here rather than in `render/1`, and only when the selected
  # agent changed: every other keystroke in the modal is then a
  # comparison, not even a cache read. The creator of the task is the
  # current user, so it is their credential that decides.
  @spec assign_model_options(Socket.t()) :: Socket.t()
  defp assign_model_options(socket) do
    socket.assigns.agents
    |> selected_agent(socket.assigns.task_form)
    |> refresh_model_options(socket)
  end

  @spec refresh_model_options(Agent.t() | nil, Socket.t()) :: Socket.t()
  defp refresh_model_options(%Agent{id: id}, %Socket{assigns: %{model_options_agent_id: id}} = socket) do
    socket
  end

  defp refresh_model_options(nil, socket) do
    assign(socket, model_options: [], model_options_agent_id: nil)
  end

  defp refresh_model_options(agent, socket) do
    options =
      agent
      |> ModelDiscovery.models_for(socket.assigns.current_user.id)
      |> Enum.map(&{ModelLabel.humanize(&1), &1})

    assign(socket, model_options: options, model_options_agent_id: agent.id)
  end

  # Guards the wire, not just the render: `disabled` on an `<option>`
  # is a hint to the browser, and a run dispatched against a CLI whose
  # key is absent only fails minutes later, inside the runner, with a
  # bare 401. Re-validating keeps the typed values and the modal, so
  # the user can switch agent instead of retyping the task.
  @spec submit_task(Socket.t(), map(), Agent.t() | nil, [atom()]) ::
          {:noreply, Socket.t()}
  defp submit_task(socket, params, agent, [_ | _] = missing) do
    {:noreply,
     socket
     |> assign(task_form: Form.validate(socket.assigns.task_form, params))
     |> put_flash(:error, missing_credential_message(agent, missing))}
  end

  defp submit_task(socket, params, _agent, []) do
    case Form.submit(socket.assigns.task_form, params: params) do
      {:ok, task} ->
        consume_uploaded_entries(socket, :attachment, fn %{path: tmp_path}, entry ->
          {:ok, TaskAttachments.store!(task.id, tmp_path, entry)}
        end)

        failures =
          create_requested_links(task, socket.assigns.parent_task, socket.assigns.blocked_by_task)

        broadcast_task_event(:task_created, task)

        # Ticks the setup guide's last step without waiting
        # for a navigation. Caught by CamelotWeb.OnboardingHook.
        send(self(), {:onboarding, :refresh})

        {:noreply,
         socket
         |> assign(
           new_task_open?: false,
           task_form: new_task_form(socket.assigns.current_user),
           parent_task: nil,
           blocked_by_task: nil
         )
         |> link_flash(failures)
         |> load_board()}

      {:error, form} ->
        Logger.warning("Task creation failed: #{inspect(Form.errors(form, format: :simple))}")

        {:noreply,
         socket
         |> assign(task_form: form)
         |> put_flash(:error, "Failed to create task")}
    end
  end

  defp load_board(socket) do
    user = socket.assigns.current_user
    see_all = socket.assigns.see_all

    tasks =
      Task
      |> Scope.maybe_scope(user, see_all, &Scope.scope_tasks/2)
      |> Ash.read!(load: [:project, :waiting_for_slot?, :blocked?])

    projects =
      Project
      |> Scope.maybe_scope(user, see_all, &Scope.scope_projects/2)
      |> Ash.read!()

    agents = Agent |> Ash.read!() |> Enum.sort_by(& &1.name)

    columns =
      Enum.map(Task.column_stages(), fn stage ->
        {stage,
         Enum.filter(tasks, fn task ->
           task.stage == stage and task.stage != :cancelled
         end)}
      end)

    socket
    |> assign(
      page_title: "Board",
      columns: columns,
      projects: projects,
      agents: agents,
      credential_kinds: UserCredentials.held_kinds(user)
    )
    |> assign_new(:task_form, fn -> new_task_form(user) end)
    |> assign_new(:model_options, fn -> [] end)
    |> assign_new(:model_options_agent_id, fn -> nil end)
  end

  # The new-task form is only submittable by a user who has a project
  # and holds the API key the chosen agent CLI needs, and PostHog's
  # dead clicks cluster on exactly the selects that say so. Each
  # refusal names its own reason, so the fix is measurable per cause.
  @spec capture_form_blocked(Socket.t()) :: Socket.t()
  defp capture_form_blocked(%Socket{assigns: %{projects: []}} = socket) do
    report_form_blocked(socket, :no_project)
  end

  # Agents are a global config table seeded by migration, so this is
  # only reachable if an admin deleted every row.
  defp capture_form_blocked(%Socket{assigns: %{agents: []}} = socket) do
    report_form_blocked(socket, :no_agent)
  end

  defp capture_form_blocked(%Socket{} = socket) do
    if any_agent_covered?(socket.assigns.agents, socket.assigns.credential_kinds) do
      socket
    else
      report_form_blocked(socket, :no_credential)
    end
  end

  # Once per mount: re-opening the modal is the same dead end, and
  # counting it again would make the funnel's denominator the number
  # of clicks rather than the number of users who hit it.
  @spec report_form_blocked(Socket.t(), atom()) :: Socket.t()
  defp report_form_blocked(%Socket{assigns: %{form_blocked_reported?: true}} = socket, _reason) do
    socket
  end

  defp report_form_blocked(socket, reason) do
    Capture.capture("task_form_blocked", socket.assigns.current_user, %{reason: reason})

    assign(socket, form_blocked_reported?: true)
  end

  @spec any_agent_covered?([Agent.t()], MapSet.t(atom())) :: boolean()
  defp any_agent_covered?(agents, held) do
    Enum.any?(agents, &UserCredentials.covered?(held, &1))
  end

  @spec new_task_form(Camelot.Accounts.User.t()) :: Phoenix.HTML.Form.t()
  defp new_task_form(user) do
    Task
    |> Form.for_create(:create,
      as: "task",
      actor: user,
      forms: [auto?: false],
      params: %{"priority" => "0"},
      prepare_params: &prepare_task_params/2,
      prepare_source: &Ash.Changeset.set_argument(&1, :creator_id, user.id)
    )
    |> to_form()
  end

  defp prepare_task_params(params, type) do
    params
    |> drop_blank_priority(type)
    |> drop_blank_next_model(type)
  end

  # A cleared number input arrives as "", which would fail the
  # non-nillable `priority` attribute instead of falling back to
  # its default.
  @spec drop_blank_priority(map(), atom()) :: map()
  defp drop_blank_priority(%{"priority" => ""} = params, _type) do
    Map.delete(params, "priority")
  end

  defp drop_blank_priority(params, _type), do: params

  # Links are created outside the `AshPhoenix.Form` create flow, right
  # where `consume_uploaded_entries/3` already runs — nesting the
  # picker picks into the Ash form would fight `AshPhoenix.Form`'s
  # nested-form machinery for no benefit, since a brand new task can't
  # already be a link target.
  # The task itself is already committed (and its attachments stored)
  # by the time the picked links are created, so a rejected link — a
  # cycle raced in between, a parent that just gained another child —
  # must not discard it. Failures are reported back so the flash can
  # name them and the user can re-add the link from the task page,
  # instead of the links vanishing behind a "Task created".
  @spec create_requested_links(Task.t(), Task.t() | nil, Task.t() | nil) :: [String.t()]
  defp create_requested_links(task, parent_task, blocked_by_task) do
    [
      create_link(parent_task, task, :parent_of),
      create_link(blocked_by_task, task, :blocks)
    ]
    |> Enum.reject(&(&1 == :ok))
    |> Enum.map(fn {:error, label} -> label end)
  end

  defp create_link(nil, _target_task, _link_type), do: :ok

  defp create_link(source_task, target_task, link_type) do
    case Ash.create(TaskLink, %{
           source_task_id: source_task.id,
           target_task_id: target_task.id,
           link_type: link_type
         }) do
      {:ok, _link} ->
        :ok

      {:error, error} ->
        Logger.warning(
          "Failed to create #{link_type} link for task " <>
            "#{target_task.id}: #{inspect(error)}"
        )

        {:error, link_label(link_type, source_task)}
    end
  end

  defp link_label(:parent_of, source_task), do: "parent \"#{source_task.title}\""
  defp link_label(:blocks, source_task), do: "blocked by \"#{source_task.title}\""

  defp link_flash(socket, []), do: put_flash(socket, :info, "Task created")

  defp link_flash(socket, failures) do
    put_flash(
      socket,
      :error,
      "Task created, but these links were rejected: " <>
        Enum.join(failures, ", ") <> ". Add them from the task page."
    )
  end

  # A blank "Use agent default" selection is stored as unset rather
  # than an empty string, so it resolves through `agent.default_model`
  # like a brand-new task.
  @spec drop_blank_next_model(map(), atom()) :: map()
  defp drop_blank_next_model(%{"next_model" => ""} = params, _type) do
    Map.delete(params, "next_model")
  end

  defp drop_blank_next_model(params, _type), do: params

  @spec selected_agent(list(Agent.t()), Phoenix.HTML.Form.t()) :: Agent.t() | nil
  defp selected_agent(agents, form) do
    agent_id = form.params["agent_id"] || form[:agent_id].value
    Enum.find(agents, &(&1.id == agent_id))
  end

  defp next_model_prompt(agents, form) do
    case selected_agent(agents, form) do
      nil -> "Select a CLI agent first"
      _agent -> "Use agent default"
    end
  end

  # An agent the user holds no key for stays in the dropdown rather
  # than being filtered out of it: the row is the only place that can
  # explain why Claude Code isn't an option today, and the user can
  # pick another CLI instead.
  @spec agent_options([Agent.t()], MapSet.t(atom())) :: [{String.t(), String.t()} | keyword()]
  defp agent_options(agents, held) do
    Enum.map(agents, &agent_option(&1, UserCredentials.missing_kinds(held, &1)))
  end

  defp agent_option(agent, []), do: {agent.name, agent.id}

  # `Phoenix.HTML.Form.options_for_select/2` passes every extra key of
  # a keyword entry straight through as an `<option>` attribute, so
  # the row is labelled and unselectable without a second branch in
  # the template.
  defp agent_option(agent, _missing) do
    [key: "#{agent.name} — API key absent", value: agent.id, disabled: true]
  end

  # At most one line, under the select: which kind the picked agent
  # still needs, or — while nothing is picked and nothing is pickable
  # — that the dropdown has no working option at all. The modal still
  # opens, because a form that says why is not a dead end.
  @spec credential_hints([Agent.t()], MapSet.t(atom()), Phoenix.HTML.Form.t()) :: [String.t()]
  defp credential_hints(agents, held, form) do
    case selected_agent(agents, form) do
      nil -> uncovered_hint(agents, held)
      agent -> selected_agent_hint(agent, UserCredentials.missing_kinds(held, agent))
    end
  end

  defp selected_agent_hint(_agent, []), do: []

  defp selected_agent_hint(agent, missing) do
    [missing_credential_message(agent, missing)]
  end

  defp uncovered_hint(agents, held) do
    if any_agent_covered?(agents, held) do
      []
    else
      ["No agent CLI has an API key yet — add one on your profile."]
    end
  end

  @spec missing_credential_message(Agent.t(), [atom()]) :: String.t()
  defp missing_credential_message(agent, missing) do
    kinds = Enum.map_join(missing, ", ", &to_string/1)

    "#{agent.name} needs a #{kinds} credential — add it on your profile."
  end

  defp broadcast_task_event(event, task) do
    Phoenix.PubSub.broadcast(
      Camelot.PubSub,
      "board",
      {event, task}
    )
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-4">
      <div class="flex items-center justify-between">
        <h1 class="text-2xl font-bold">Board</h1>
        <div class="flex items-center gap-2">
          <button
            :if={@current_user.role == :admin}
            phx-click="toggle_scope"
            class="btn btn-ghost btn-sm"
          >
            Showing: <span class="font-bold">{if @see_all, do: "All", else: "Mine"}</span>
          </button>
          <button
            class="btn btn-primary btn-sm"
            phx-click={show_modal("new-task-modal") |> JS.push("open_new_task")}
          >
            New Task
          </button>
        </div>
      </div>

      <div class="flex gap-3 overflow-x-auto pb-4">
        <.column
          :for={{stage, tasks} <- @columns}
          stage={stage}
          tasks={tasks}
        >
          <.task_card
            :for={task <- tasks}
            task={task}
            on_click={JS.navigate(~p"/tasks/#{task.id}")}
          />
        </.column>
      </div>

      <.modal
        id="new-task-modal"
        show={@new_task_open?}
        on_cancel={hide_modal("new-task-modal") |> JS.push("close_new_task")}
      >
        <h3 class="font-bold text-lg mb-4">New Task</h3>
        <.simple_form
          for={@task_form}
          phx-change="validate_task"
          phx-submit="create_task"
          id="new-task-form"
        >
          <.input
            field={@task_form[:title]}
            type="text"
            label="Title"
            required
          />
          <.input
            field={@task_form[:description]}
            type="textarea"
            label="Description"
          />
          <.input
            field={@task_form[:project_id]}
            type="select"
            label="Project"
            prompt="Select project"
            options={Enum.map(@projects, &{&1.name, &1.id})}
            required
          />
          <.input
            field={@task_form[:agent_id]}
            type="select"
            label="CLI Agent"
            prompt="Select agent CLI"
            options={agent_options(@agents, @credential_kinds)}
            required
          />
          <p
            :for={hint <- credential_hints(@agents, @credential_kinds, @task_form)}
            class="text-xs text-error"
          >
            {hint}
          </p>
          <.input
            field={@task_form[:next_model]}
            type="select"
            label="Model"
            prompt={next_model_prompt(@agents, @task_form)}
            options={@model_options}
            disabled={is_nil(selected_agent(@agents, @task_form))}
          />
          <fieldset class="fieldset">
            <label class="label" for={@uploads.attachment.ref}>
              Attachments
            </label>
            <.live_file_input upload={@uploads.attachment} class="text-sm" />
            <p :for={err <- upload_errors(@uploads.attachment)} class="text-xs text-error">
              {TaskAttachments.error_to_string(err)}
            </p>
          </fieldset>
          <.live_component
            module={TaskPicker}
            id="new-task-parent-picker"
            label="Parent task"
            field={:parent_task}
            selected={@parent_task}
            current_user={@current_user}
            see_all?={@see_all}
            placeholder="Search for the umbrella task…"
          />
          <.live_component
            module={TaskPicker}
            id="new-task-blocked-by-picker"
            label="Blocked by"
            field={:blocked_by_task}
            selected={@blocked_by_task}
            current_user={@current_user}
            see_all?={@see_all}
            placeholder="Search for a prerequisite task…"
          />
          <:actions>
            <.button class="btn btn-primary">
              Create Task
            </.button>
          </:actions>
        </.simple_form>
      </.modal>
    </div>
    """
  end
end
