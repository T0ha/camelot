defmodule CamelotWeb.BoardLive do
  @moduledoc """
  Kanban board LiveView — main page of the application.
  Displays tasks organized by status columns with
  real-time PubSub updates.
  """
  use CamelotWeb, :live_view

  import CamelotWeb.BoardComponents

  alias Camelot.Board.Task
  alias Camelot.Projects.Project
  alias Phoenix.LiveView.Socket

  @impl true
  @spec mount(map(), map(), Socket.t()) ::
          {:ok, Socket.t()}
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Camelot.PubSub, "board")
    end

    {:ok, load_board(socket)}
  end

  @impl true
  def handle_info({:task_updated, _task}, socket) do
    {:noreply, load_board(socket)}
  end

  def handle_info({:task_created, _task}, socket) do
    # load_board(socket)}
    {:noreply, socket}
  end

  @impl true
  @task_fields ~w(title description priority project_id)

  def handle_event("create_task", params, socket) do
    user = socket.assigns.current_user
    task_params = Map.take(params, @task_fields)

    case Ash.create(Task, Map.put(task_params, "creator_id", user.id)) do
      {:ok, task} ->
        broadcast_task_event(:task_created, task)

        {:noreply,
         socket
         |> put_flash(:info, "Task created")
         |> load_board()}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Failed to create task")}
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

  defp load_board(socket) do
    tasks = Ash.read!(Task, load: [:project])
    projects = Ash.read!(Project)

    columns =
      Enum.map(Task.column_statuses(), fn status ->
        {status, Enum.filter(tasks, &(&1.status == status))}
      end)

    assign(socket,
      page_title: "Board",
      columns: columns,
      projects: projects,
      task_form:
        to_form(%{
          "title" => "",
          "description" => "",
          "priority" => "0",
          "project_id" => ""
        })
    )
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
        <button
          class="btn btn-primary btn-sm"
          phx-click={show_modal("new-task-modal")}
        >
          New Task
        </button>
      </div>

      <div class="flex gap-3 overflow-x-auto pb-4">
        <.column
          :for={{status, tasks} <- @columns}
          status={status}
          tasks={tasks}
        >
          <.task_card
            :for={task <- tasks}
            task={task}
            on_click={JS.navigate(~p"/tasks/#{task.id}")}
          />
        </.column>
      </div>

      <.modal id="new-task-modal">
        <h3 class="font-bold text-lg mb-4">New Task</h3>
        <.simple_form
          for={@task_form}
          phx-submit={
            hide_modal("new-task-modal")
            |> JS.push("create_task")
          }
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
          />
          <.input
            field={@task_form[:priority]}
            type="number"
            label="Priority"
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
