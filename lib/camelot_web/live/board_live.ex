defmodule CamelotWeb.BoardLive do
  @moduledoc """
  Kanban board LiveView — main page of the application.
  Displays tasks organized by stage columns with
  real-time PubSub updates.
  """
  use CamelotWeb, :live_view

  import CamelotWeb.BoardComponents

  alias AshPhoenix.Form
  alias Camelot.Agents.Agent
  alias Camelot.Agents.ModelLabel
  alias Camelot.Board.Task
  alias Camelot.Board.TaskLink
  alias Camelot.Projects.Project
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
        new_task_open?: false,
        parent_task: nil,
        blocked_by_task: nil
      )
      |> load_board()
      |> allow_upload(:attachment, accept: :any, max_entries: 5, max_file_size: 25_000_000)

    {:ok, socket}
  end

  @impl true
  def handle_info({:task_updated, _task}, socket) do
    {:noreply, load_board(socket)}
  end

  def handle_info({:task_created, _task}, socket) do
    {:noreply, socket}
  end

  def handle_info({:task_selected, field, task}, socket) when field in [:parent_task, :blocked_by_task] do
    {:noreply, assign(socket, field, task)}
  end

  def handle_info({:task_cleared, field}, socket) when field in [:parent_task, :blocked_by_task] do
    {:noreply, assign(socket, field, nil)}
  end

  # Never crash the board on an unexpected PubSub message.
  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def handle_event("open_new_task", _params, socket) do
    {:noreply, assign(socket, new_task_open?: true)}
  end

  def handle_event("close_new_task", _params, socket) do
    {:noreply, assign(socket, new_task_open?: false)}
  end

  def handle_event("validate_task", %{"task" => params}, socket) do
    {:noreply, assign(socket, task_form: Form.validate(socket.assigns.task_form, params))}
  end

  def handle_event("create_task", %{"task" => params}, socket) do
    case Form.submit(socket.assigns.task_form, params: params) do
      {:ok, task} ->
        consume_uploaded_entries(socket, :attachment, fn %{path: tmp_path}, entry ->
          {:ok, TaskAttachments.store!(task.id, tmp_path, entry)}
        end)

        create_requested_links(task, socket.assigns.parent_task, socket.assigns.blocked_by_task)
        broadcast_task_event(:task_created, task)

        {:noreply,
         socket
         |> assign(
           new_task_open?: false,
           task_form: new_task_form(socket.assigns.current_user),
           parent_task: nil,
           blocked_by_task: nil
         )
         |> put_flash(:info, "Task created")
         |> load_board()}

      {:error, form} ->
        Logger.warning("Task creation failed: #{inspect(Form.errors(form, format: :simple))}")

        {:noreply,
         socket
         |> assign(task_form: form)
         |> put_flash(:error, "Failed to create task")}
    end
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
      agents: agents
    )
    |> assign_new(:task_form, fn -> new_task_form(user) end)
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
  defp create_requested_links(task, parent_task, blocked_by_task) do
    create_link(parent_task, task, :parent_of)
    create_link(blocked_by_task, task, :blocks)
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
        Logger.warning("Failed to create #{link_type} link for task #{target_task.id}: #{inspect(error)}")
    end
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

  defp next_model_options(agents, form) do
    case selected_agent(agents, form) do
      nil -> []
      agent -> Enum.map(agent.available_models, &{ModelLabel.humanize(&1), &1})
    end
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
            options={Enum.map(@agents, &{&1.name, &1.id})}
            required
          />
          <.input
            field={@task_form[:next_model]}
            type="select"
            label="Model"
            prompt={next_model_prompt(@agents, @task_form)}
            options={next_model_options(@agents, @task_form)}
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
