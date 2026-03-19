defmodule CamelotWeb.BoardComponents do
  @moduledoc """
  Components for the kanban board: columns, task cards.
  """
  use Phoenix.Component

  import CamelotWeb.CoreComponents, only: [icon: 1]

  alias Phoenix.LiveView.Rendered

  attr :status, :atom, required: true
  attr :tasks, :list, required: true

  slot :inner_block

  @spec column(map()) :: Rendered.t()
  def column(assigns) do
    ~H"""
    <div class="flex flex-col min-w-[220px] max-w-[280px] flex-1">
      <div class="flex items-center gap-2 mb-3 px-2">
        <span class={[
          "badge badge-sm",
          status_badge_class(@status)
        ]}>
          {format_status(@status)}
        </span>
        <span class="text-xs text-base-content/50">
          {length(@tasks)}
        </span>
      </div>
      <div class="flex flex-col gap-2 min-h-[200px] p-2 bg-base-200 rounded-lg">
        {render_slot(@inner_block)}
        <div
          :if={@tasks == []}
          class="text-xs text-base-content/40 text-center py-8"
        >
          No tasks
        </div>
      </div>
    </div>
    """
  end

  attr :task, :map, required: true
  attr :on_click, :any, default: nil
  attr :error, :boolean, default: false

  @spec task_card(map()) :: Rendered.t()
  def task_card(assigns) do
    ~H"""
    <div
      class={[
        "card bg-base-100 shadow-sm cursor-pointer",
        "hover:shadow-md transition-shadow",
        @error && "border border-error/40"
      ]}
      phx-click={@on_click}
    >
      <div class="card-body p-3">
        <h3 class="card-title text-sm">
          {@task.title}
        </h3>
        <p
          :if={@task.description}
          class="text-xs text-base-content/60 line-clamp-2"
        >
          {@task.description}
        </p>
        <div class="flex items-center gap-2 mt-1">
          <span
            :if={@error}
            class={[
              "badge badge-xs",
              status_badge_class(@task.status)
            ]}
          >
            {format_status(@task.status)}
          </span>
          <span
            :if={@task.pr_url}
            class="badge badge-xs badge-outline"
          >
            <.icon name="hero-code-bracket" class="size-3" /> PR #{@task.pr_number}
          </span>
          <span class="badge badge-xs badge-ghost">
            P{@task.priority}
          </span>
        </div>
      </div>
    </div>
    """
  end

  defp format_status(status) do
    status
    |> Atom.to_string()
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  defp status_badge_class(:planning), do: "badge-info"
  defp status_badge_class(:plan_review), do: "badge-warning"
  defp status_badge_class(:executing), do: "badge-primary"
  defp status_badge_class(:pr_created), do: "badge-secondary"
  defp status_badge_class(:pr_review), do: "badge-warning"
  defp status_badge_class(:pr_fix), do: "badge-error"
  defp status_badge_class(:done), do: "badge-success"
  defp status_badge_class(:error), do: "badge-error"
  defp status_badge_class(_status), do: "badge-ghost"
end
