defmodule CamelotWeb.Components.EnvVarEditor do
  @moduledoc """
  Reusable editor for scoped `Camelot.Projects.EnvVar` rows.

  Parameterised by `scope`, so the same component drives the
  project, agent, user, and global surfaces:

      <.live_component
        module={CamelotWeb.Components.EnvVarEditor}
        id="project-env-vars"
        scope={{:project, @project.id}}
      />

  Accepts `{:project, id}`, `{:agent, id}`, `{:user, id}`, or
  `:global`. Values marked `secret` are masked in the table;
  storage is always encrypted regardless of the flag.
  """
  use CamelotWeb, :live_component

  alias Camelot.Projects.EnvVar

  require Ash.Query

  @impl true
  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign(env_vars: list_env_vars(assigns.scope))
     |> assign_new(:form, fn -> to_form(blank_params()) end)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="space-y-4">
      <h2 class="text-lg font-semibold">Environment variables</h2>

      <.table :if={@env_vars != []} id={"env-vars-#{@id}"} rows={@env_vars}>
        <:col :let={env_var} label="Key">
          <code>{env_var.key}</code>
        </:col>
        <:col :let={env_var} label="Value">
          <code>{display_value(env_var)}</code>
        </:col>
        <:col :let={env_var} label="Secret">
          <span :if={env_var.secret} class="badge badge-warning">secret</span>
        </:col>
        <:action :let={env_var}>
          <.button
            type="button"
            phx-click="delete_env_var"
            phx-value-id={env_var.id}
            phx-target={@myself}
            data-confirm="Delete this variable?"
            class="btn btn-xs btn-ghost text-error"
          >
            Delete
          </.button>
        </:action>
      </.table>

      <p :if={@env_vars == []} class="text-sm text-base-content/60">
        No environment variables yet.
      </p>

      <.simple_form
        for={@form}
        id={"env-var-form-#{@id}"}
        phx-submit="add_env_var"
        phx-change="validate_env_var"
        phx-target={@myself}
      >
        <div class="flex flex-wrap gap-3 items-end">
          <.input field={@form[:key]} type="text" label="Key" placeholder="DATABASE_URL" />
          <.input field={@form[:value]} type="text" label="Value" />
          <.input field={@form[:secret]} type="checkbox" label="Secret" />
          <.button phx-disable-with="Adding..." class="btn btn-primary btn-sm">
            Add
          </.button>
        </div>
      </.simple_form>
    </section>
    """
  end

  @impl true
  def handle_event("validate_env_var", params, socket) do
    {:noreply, assign(socket, form: to_form(Map.take(params, ~w(key value secret))))}
  end

  def handle_event("add_env_var", params, socket) do
    attrs =
      params
      |> Map.take(~w(key value))
      |> Map.put("secret", params["secret"] == "true")
      |> Map.merge(scope_attrs(socket.assigns.scope))

    case Ash.create(EnvVar, attrs, authorize?: false) do
      {:ok, _env_var} ->
        {:noreply,
         socket
         |> assign(env_vars: list_env_vars(socket.assigns.scope))
         |> assign(form: to_form(blank_params()))}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(Map.get(changeset, :params, params)))}
    end
  end

  def handle_event("delete_env_var", %{"id" => id}, socket) do
    EnvVar
    |> Ash.get!(id, authorize?: false)
    |> Ash.destroy!(authorize?: false)

    {:noreply, assign(socket, env_vars: list_env_vars(socket.assigns.scope))}
  end

  defp list_env_vars(scope) do
    scope
    |> scope_query()
    |> Ash.Query.load(:value)
    |> Ash.Query.sort(:key)
    |> Ash.read!(authorize?: false)
  end

  defp scope_query({:project, id}), do: Ash.Query.filter(EnvVar, project_id == ^id)
  defp scope_query({:agent, id}), do: Ash.Query.filter(EnvVar, agent_id == ^id)
  defp scope_query({:user, id}), do: Ash.Query.filter(EnvVar, user_id == ^id)

  defp scope_query(:global) do
    Ash.Query.filter(EnvVar, is_nil(project_id) and is_nil(agent_id) and is_nil(user_id))
  end

  defp scope_attrs({:project, id}), do: %{"project_id" => id}
  defp scope_attrs({:agent, id}), do: %{"agent_id" => id}
  defp scope_attrs({:user, id}), do: %{"user_id" => id}
  defp scope_attrs(:global), do: %{}

  defp display_value(%EnvVar{secret: true}), do: "••••••••"
  defp display_value(%EnvVar{value: value}), do: value

  defp blank_params, do: %{"key" => "", "value" => "", "secret" => false}
end
