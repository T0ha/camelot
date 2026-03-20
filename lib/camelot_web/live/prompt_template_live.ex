defmodule CamelotWeb.PromptTemplateLive do
  @moduledoc """
  LiveView for listing and managing prompt templates.
  """
  use CamelotWeb, :live_view

  alias Camelot.Projects.Project
  alias Camelot.Prompts.PromptTemplate

  @impl true
  def mount(_params, _session, socket) do
    {:ok, load_templates(socket)}
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
    assign(socket,
      page_title: "New Template",
      template: nil,
      form: to_form(template_create_params()),
      projects: load_projects()
    )
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    template = Ash.get!(PromptTemplate, id)

    assign(socket,
      page_title: "Edit Template",
      template: template,
      form: to_form(template_update_params(template)),
      projects: load_projects()
    )
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    template = Ash.get!(PromptTemplate, id)
    Ash.destroy!(template)

    {:noreply,
     socket
     |> put_flash(:info, "Template deleted")
     |> load_templates()}
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

  defp save_template(socket, :new, params) do
    params = normalize_project_id(params)

    case Ash.create(PromptTemplate, params, action: :create) do
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
    templates = Ash.read!(PromptTemplate, load: [:project])

    assign(socket, templates: templates)
  end

  defp load_projects do
    Ash.read!(Project)
  end

  defp template_create_params do
    %{
      "slug" => "",
      "name" => "",
      "body" => "",
      "description" => "",
      "project_id" => ""
    }
  end

  defp template_update_params(template) do
    %{
      "name" => template.name || "",
      "body" => template.body || "",
      "description" => template.description || ""
    }
  end

  @template_fields ~w(slug name body description project_id)

  defp extract_params(params) do
    Map.take(params, @template_fields)
  end

  defp normalize_project_id(%{"project_id" => ""} = params) do
    Map.put(params, "project_id", nil)
  end

  defp normalize_project_id(params), do: params

  defp scope_label(template) do
    if Ash.Resource.loaded?(template, :project) &&
         template.project do
      template.project.name
    else
      "Global"
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
        <.link
          navigate={~p"/prompts/new"}
          class="btn btn-primary"
        >
          New Template
        </.link>
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
                field={@form[:project_id]}
                type="select"
                label="Scope"
                options={
                  [{"Global", ""}] ++
                    Enum.map(@projects, &{&1.name, &1.id})
                }
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
              if(scope_label(template) == "Global",
                do: "badge-ghost",
                else: "badge-info"
              )
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
            <.link navigate={~p"/prompts/#{template.id}/edit"}>
              Edit
            </.link>
          </:action>
          <:action :let={template}>
            <.link
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
end
