defmodule CamelotWeb.PromptTemplateLive do
  @moduledoc """
  LiveView for listing and managing prompt templates.

  Visibility model:
    * System-global (no project, no user) — admin-managed; visible to everyone.
    * User-global (user_id set, no project) — visible/editable by that user.
    * Project-scoped (project_id set) — visible/editable by project members.

  Admins see and edit everything. Non-admins default the "Showing" filter to
  their own scope; toggling to "All" is admin-only.
  """
  use CamelotWeb, :live_view

  alias Camelot.Accounts.User
  alias Camelot.Projects.Membership
  alias Camelot.Projects.Project
  alias Camelot.Prompts.PromptTemplate
  alias CamelotWeb.Scope

  require Ash.Query

  @impl true
  def mount(params, _session, socket) do
    {:ok, socket |> assign(see_all: params["scope"] == "all") |> load_templates()}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    assign(socket,
      page_title: "Prompt Templates",
      template: nil
    )
  end

  defp apply_action(socket, :new, _params) do
    user = socket.assigns.current_user
    projects = scoped_projects(user)

    assign(socket,
      page_title: "New Template",
      template: nil,
      form: to_form(template_create_params(user)),
      projects: projects,
      scope_options: scope_options(user, projects)
    )
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    user = socket.assigns.current_user
    template = Ash.get!(PromptTemplate, id)

    if writable?(template, user) do
      projects = scoped_projects(user)

      assign(socket,
        page_title: "Edit Template",
        template: template,
        form: to_form(template_update_params(template)),
        projects: projects,
        scope_options: scope_options(user, projects)
      )
    else
      socket
      |> put_flash(:error, "You don't have access to edit that prompt.")
      |> push_navigate(to: ~p"/prompts")
    end
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    user = socket.assigns.current_user
    template = Ash.get!(PromptTemplate, id)

    if writable?(template, user) do
      Ash.destroy!(template)

      {:noreply,
       socket
       |> put_flash(:info, "Template deleted")
       |> load_templates()}
    else
      {:noreply, put_flash(socket, :error, "You don't have access to delete that prompt.")}
    end
  end

  def handle_event("validate", params, socket) do
    {:noreply, assign(socket, form: to_form(extract_params(params)))}
  end

  def handle_event("save", params, socket) do
    save_template(
      socket,
      socket.assigns.live_action,
      extract_params(params)
    )
  end

  def handle_event("toggle_scope", _params, socket) do
    {:noreply, socket |> assign(see_all: !socket.assigns.see_all) |> load_templates()}
  end

  defp save_template(socket, :new, params) do
    user = socket.assigns.current_user
    create_attrs = resolve_create_scope(params, user)

    case Ash.create(PromptTemplate, create_attrs, action: :create) do
      {:ok, _template} ->
        {:noreply,
         socket
         |> put_flash(:info, "Template created")
         |> push_navigate(to: ~p"/prompts")}

      {:error, changeset} ->
        {:noreply,
         assign(socket,
           form: to_form(Map.get(changeset, :params, params))
         )}
    end
  end

  defp save_template(socket, :edit, params) do
    case Ash.update(
           socket.assigns.template,
           params,
           action: :update
         ) do
      {:ok, _template} ->
        {:noreply,
         socket
         |> put_flash(:info, "Template updated")
         |> push_navigate(to: ~p"/prompts")}

      {:error, changeset} ->
        {:noreply,
         assign(socket,
           form: to_form(Map.get(changeset, :params, params))
         )}
    end
  end

  defp load_templates(socket) do
    user = socket.assigns.current_user

    templates =
      PromptTemplate
      |> Scope.maybe_scope(user, socket.assigns.see_all, &Scope.scope_prompts/2)
      |> Ash.read!(load: [:project, :user])

    assign(socket, templates: templates)
  end

  defp scoped_projects(%User{role: :admin}), do: Ash.read!(Project)

  defp scoped_projects(%User{} = user) do
    Project
    |> Scope.scope_projects(user)
    |> Ash.read!()
  end

  defp template_create_params(_user) do
    %{
      "slug" => "",
      "name" => "",
      "body" => "",
      "description" => "",
      "scope" => "user"
    }
  end

  defp template_update_params(template) do
    %{
      "name" => template.name || "",
      "body" => template.body || "",
      "description" => template.description || ""
    }
  end

  @template_fields ~w(slug name body description scope)

  defp extract_params(params) do
    Map.take(params, @template_fields)
  end

  # Admin can create system-global or project-scoped (no user-global on UI for v1).
  # Non-admin can create user-global (default) or project-scoped (must be a member).
  defp resolve_create_scope(params, user) do
    base = Map.take(params, ~w(slug name body description))

    case {params["scope"], user} do
      {"system", %User{role: :admin}} ->
        Map.merge(base, %{"project_id" => nil, "user_id" => nil})

      {"user", %User{id: uid}} ->
        Map.merge(base, %{"project_id" => nil, "user_id" => uid})

      {project_id, _} when is_binary(project_id) and project_id != "" ->
        Map.merge(base, %{"project_id" => project_id, "user_id" => nil})

      _ ->
        # Fallback: user-global for the actor.
        Map.merge(base, %{"project_id" => nil, "user_id" => user.id})
    end
  end

  defp scope_options(%User{role: :admin}, projects) do
    [{"System Global", "system"}] ++ Enum.map(projects, &{&1.name, &1.id})
  end

  defp scope_options(%User{}, projects) do
    [{"My User Global", "user"}] ++ Enum.map(projects, &{&1.name, &1.id})
  end

  defp writable?(_template, %User{role: :admin}), do: true

  defp writable?(%PromptTemplate{user_id: uid, project_id: nil}, %User{id: uid}) when not is_nil(uid), do: true

  defp writable?(%PromptTemplate{project_id: pid}, %User{id: uid}) when not is_nil(pid) do
    Membership
    |> Ash.Query.filter(project_id == ^pid and user_id == ^uid)
    |> Ash.read!()
    |> case do
      [] -> false
      _ -> true
    end
  end

  defp writable?(_template, _user), do: false

  defp scope_label(%PromptTemplate{project_id: nil, user_id: nil}), do: "Global"

  defp scope_label(%PromptTemplate{project_id: nil} = t) do
    case Ash.Resource.loaded?(t, :user) && t.user do
      %{email: email} -> "#{email} (user)"
      _ -> "User"
    end
  end

  defp scope_label(%PromptTemplate{} = t) do
    case Ash.Resource.loaded?(t, :project) && t.project do
      %{name: name} -> name
      _ -> "Project"
    end
  end

  defp truncate(nil, _), do: ""

  defp truncate(text, max_length) do
    if String.length(text) > max_length do
      String.slice(text, 0, max_length) <> "..."
    else
      text
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="flex items-center justify-between">
        <h1 class="text-2xl font-bold">Prompt Templates</h1>
        <div class="flex items-center gap-2">
          <button
            :if={@current_user.role == :admin}
            phx-click="toggle_scope"
            class="btn btn-ghost btn-sm"
          >
            Showing: <span class="font-bold">{if @see_all, do: "All", else: "Mine"}</span>
          </button>
          <.link
            navigate={~p"/prompts/new"}
            class="btn btn-primary"
          >
            New Template
          </.link>
        </div>
      </div>

      <%= if @live_action in [:new, :edit] do %>
        <.modal
          id="template-modal"
          show
          on_cancel={JS.navigate(~p"/prompts")}
        >
          <.header>
            {@page_title}
          </.header>

          <.simple_form
            for={@form}
            id="template-form"
            phx-change="validate"
            phx-submit="save"
          >
            <%= if @live_action == :new do %>
              <.input
                field={@form[:slug]}
                type="text"
                label="Slug"
                placeholder="e.g. planning, execution"
              />
              <.input
                field={@form[:scope]}
                type="select"
                label="Scope"
                options={@scope_options}
              />
            <% end %>
            <.input
              field={@form[:name]}
              type="text"
              label="Name"
            />
            <.input
              field={@form[:body]}
              type="textarea"
              label="Body"
              rows="8"
            />
            <p class="text-xs text-base-content/50 -mt-2">
              Available variables: <code>{"{{title}}"}</code>, <code>{"{{description}}"}</code>,
              <code>{"{{plan}}"}</code>
            </p>
            <.input
              field={@form[:description]}
              type="textarea"
              label="Description"
              rows="2"
            />
            <:actions>
              <.button
                phx-disable-with="Saving..."
                class="btn btn-primary"
              >
                Save
              </.button>
            </:actions>
          </.simple_form>
        </.modal>
      <% end %>

      <div class="overflow-x-auto">
        <.table id="templates" rows={@templates}>
          <:col :let={template} label="Slug">
            <code>{template.slug}</code>
          </:col>
          <:col :let={template} label="Name">
            {template.name}
          </:col>
          <:col :let={template} label="Scope">
            <span class={[
              "badge",
              scope_badge_class(template)
            ]}>
              {scope_label(template)}
            </span>
          </:col>
          <:col :let={template} label="Body">
            <code class="text-xs">
              {truncate(template.body, 60)}
            </code>
          </:col>
          <:action :let={template}>
            <.link
              :if={writable?(template, @current_user)}
              navigate={~p"/prompts/#{template.id}/edit"}
            >
              Edit
            </.link>
          </:action>
          <:action :let={template}>
            <.link
              :if={writable?(template, @current_user)}
              phx-click={
                JS.push("delete",
                  value: %{id: template.id}
                )
              }
              data-confirm="Are you sure?"
            >
              Delete
            </.link>
          </:action>
        </.table>
      </div>
    </div>
    """
  end

  defp scope_badge_class(%PromptTemplate{project_id: nil, user_id: nil}), do: "badge-ghost"
  defp scope_badge_class(%PromptTemplate{project_id: nil}), do: "badge-secondary"
  defp scope_badge_class(_), do: "badge-info"
end
