defmodule CamelotWeb.TaskPlanLive do
  @moduledoc """
  Full-width, deep-linkable view of a task's plan document.

  Renders `full_plan` — the complete document captured from the
  plan file the agent wrote in its workspace — falling back to
  `plan` (the inline text the agent returned) for tasks captured
  before `full_plan` existed or when no plan file was referenced.
  """
  use CamelotWeb, :live_view

  alias Camelot.Accounts.User
  alias Camelot.Board.Task
  alias CamelotWeb.Markdown
  alias CamelotWeb.Scope

  require Ash.Query

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case load_or_forbid(id, socket.assigns.current_user) do
      {:ok, task} ->
        {:ok,
         assign(socket,
           page_title: "Plan — #{task.title}",
           task: task
         )}

      :forbidden ->
        {:ok,
         socket
         |> put_flash(:error, "Task not found")
         |> push_navigate(to: ~p"/")}
    end
  end

  defp load_or_forbid(id, %User{role: :admin}) do
    case Ash.get(Task, id) do
      {:ok, task} -> {:ok, task}
      _ -> :forbidden
    end
  end

  defp load_or_forbid(id, %User{} = user) do
    case Task
         |> Ash.Query.filter(id == ^id)
         |> Scope.scope_tasks(user)
         |> Ash.read_one() do
      {:ok, %Task{} = task} -> {:ok, task}
      _ -> :forbidden
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-4xl mx-auto p-4 space-y-4">
      <div class="flex items-center justify-between">
        <div>
          <.link
            navigate={~p"/tasks/#{@task.id}"}
            class="text-sm link link-hover"
          >
            &larr; {@task.title}
          </.link>
          <h2 class="text-xl font-bold">Plan</h2>
        </div>
        <a
          href={~p"/tasks/#{@task.id}/plan/download"}
          class="btn btn-sm btn-ghost"
        >
          <.icon name="hero-arrow-down-tray" class="size-4" /> Download
        </a>
      </div>

      <div
        :if={plan_text(@task)}
        class="prose max-w-none overflow-x-auto"
      >
        {Markdown.render(plan_text(@task))}
      </div>

      <p :if={is_nil(plan_text(@task))} class="text-base-content/50">
        This task has no plan yet.
      </p>
    </div>
    """
  end

  defp plan_text(task), do: task.full_plan || task.plan
end
