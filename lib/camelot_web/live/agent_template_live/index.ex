defmodule CamelotWeb.AgentTemplateLive.Index do
  @moduledoc """
  LiveView for managing AgentTemplate rows.

  Array fields (base_args, internal_tools, question_phrases)
  are edited as one-entry-per-line textareas. Map fields
  (permission_args_by_stage, env_vars) are edited as JSON
  textareas and validated on save.
  """
  use CamelotWeb, :live_view

  alias Camelot.Agents.AgentTemplate

  @parser_options [
    {"Claude Code JSON", "claude_code_json"},
    {"Raw Text", "raw_text"}
  ]

  @text_fields ~w(slug name command_prefix executable prompt_flag
                  tools_flag tools_separator parser pr_url_pattern)
  @array_fields ~w(base_args internal_tools question_phrases)
  @map_fields ~w(permission_args_by_stage env_vars)
  @integer_fields ~w(base_retry_delay_ms)

  @impl true
  def mount(_params, _session, socket) do
    {:ok, load_templates(socket)}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    assign(socket, page_title: "Agent Templates", template: nil)
  end

  defp apply_action(socket, :new, _params) do
    assign(socket,
      page_title: "New Agent Template",
      template: nil,
      form: to_form(blank_form()),
      parser_options: @parser_options
    )
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    template = Ash.get!(AgentTemplate, id)

    assign(socket,
      page_title: "Edit Agent Template",
      template: template,
      form: to_form(template_to_form(template)),
      parser_options: @parser_options
    )
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    template = Ash.get!(AgentTemplate, id)
    Ash.destroy!(template)

    {:noreply,
     socket
     |> put_flash(:info, "Template deleted")
     |> load_templates()}
  end

  def handle_event("validate", params, socket) do
    {:noreply, assign(socket, form: to_form(form_params(params)))}
  end

  def handle_event("save", params, socket) do
    form_p = form_params(params)

    case build_attrs(form_p) do
      {:ok, attrs} ->
        save_template(socket, socket.assigns.live_action, attrs, form_p)

      {:error, msg} ->
        {:noreply,
         socket
         |> put_flash(:error, msg)
         |> assign(form: to_form(form_p))}
    end
  end

  defp save_template(socket, :new, attrs, form_p) do
    case Ash.create(AgentTemplate, attrs, action: :create) do
      {:ok, _template} ->
        {:noreply,
         socket
         |> put_flash(:info, "Template created")
         |> push_navigate(to: ~p"/agent-templates")}

      {:error, _changeset} ->
        {:noreply,
         socket
         |> put_flash(:error, "Failed to create template")
         |> assign(form: to_form(form_p))}
    end
  end

  defp save_template(socket, :edit, attrs, form_p) do
    attrs = Map.delete(attrs, :slug)

    case Ash.update(socket.assigns.template, attrs, action: :update) do
      {:ok, _template} ->
        {:noreply,
         socket
         |> put_flash(:info, "Template updated")
         |> push_navigate(to: ~p"/agent-templates")}

      {:error, _changeset} ->
        {:noreply,
         socket
         |> put_flash(:error, "Failed to update template")
         |> assign(form: to_form(form_p))}
    end
  end

  defp load_templates(socket) do
    templates = Ash.read!(AgentTemplate)
    assign(socket, templates: Enum.sort_by(templates, & &1.slug))
  end

  defp blank_form do
    %{
      "slug" => "",
      "name" => "",
      "command_prefix" => "",
      "executable" => "",
      "base_args" => "",
      "prompt_flag" => "",
      "tools_flag" => "",
      "tools_separator" => ",",
      "permission_args_by_stage" => "{}",
      "internal_tools" => "",
      "env_vars" => "{}",
      "parser" => "raw_text",
      "pr_url_pattern" => "https://github\\.com/[^\\s]+/pull/(\\d+)",
      "question_phrases" => "",
      "base_retry_delay_ms" => "5000"
    }
  end

  defp template_to_form(template) do
    %{
      "slug" => template.slug,
      "name" => template.name,
      "command_prefix" => template.command_prefix || "",
      "executable" => template.executable,
      "base_args" => lines(template.base_args),
      "prompt_flag" => template.prompt_flag || "",
      "tools_flag" => template.tools_flag || "",
      "tools_separator" => template.tools_separator,
      "permission_args_by_stage" => Jason.encode!(template.permission_args_by_stage, pretty: true),
      "internal_tools" => lines(template.internal_tools),
      "env_vars" => Jason.encode!(template.env_vars, pretty: true),
      "parser" => to_string(template.parser),
      "pr_url_pattern" => template.pr_url_pattern,
      "question_phrases" => lines(template.question_phrases),
      "base_retry_delay_ms" => to_string(template.base_retry_delay_ms)
    }
  end

  defp form_params(params) do
    fields = @text_fields ++ @array_fields ++ @map_fields ++ @integer_fields
    Map.take(params, fields)
  end

  defp build_attrs(form_p) do
    with {:ok, perm} <- parse_json_map(form_p, "permission_args_by_stage"),
         {:ok, env} <- parse_json_map(form_p, "env_vars"),
         {:ok, retry_ms} <- parse_int(form_p, "base_retry_delay_ms") do
      {:ok,
       %{
         slug: form_p["slug"],
         name: form_p["name"],
         command_prefix: nilify(form_p["command_prefix"]),
         executable: form_p["executable"],
         base_args: split_lines(form_p["base_args"]),
         prompt_flag: nilify(form_p["prompt_flag"]),
         tools_flag: nilify(form_p["tools_flag"]),
         tools_separator: form_p["tools_separator"] || ",",
         permission_args_by_stage: perm,
         internal_tools: split_lines(form_p["internal_tools"]),
         env_vars: env,
         parser: parse_atom(form_p["parser"]),
         pr_url_pattern: form_p["pr_url_pattern"],
         question_phrases: split_lines(form_p["question_phrases"]),
         base_retry_delay_ms: retry_ms
       }}
    end
  end

  defp parse_json_map(form_p, key) do
    case Jason.decode(form_p[key] || "{}") do
      {:ok, %{} = map} -> {:ok, map}
      {:ok, _} -> {:error, "#{key} must be a JSON object"}
      {:error, _} -> {:error, "#{key} is not valid JSON"}
    end
  end

  defp parse_int(form_p, key) do
    case Integer.parse(form_p[key] || "") do
      {n, ""} when n > 0 -> {:ok, n}
      _ -> {:error, "#{key} must be a positive integer"}
    end
  end

  defp parse_atom("claude_code_json"), do: :claude_code_json
  defp parse_atom(_), do: :raw_text

  defp nilify(""), do: nil
  defp nilify(nil), do: nil
  defp nilify(s), do: s

  defp split_lines(nil), do: []

  defp split_lines(text) do
    text
    |> String.split(~r/\R/, trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp lines(list) when is_list(list), do: Enum.join(list, "\n")
  defp lines(_), do: ""

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="flex items-center justify-between">
        <h1 class="text-2xl font-bold">Agent Templates</h1>
        <.link
          navigate={~p"/agent-templates/new"}
          class="btn btn-primary"
        >
          New Template
        </.link>
      </div>

      <%= if @live_action in [:new, :edit] do %>
        <.modal
          id="agent-template-modal"
          show
          on_cancel={JS.navigate(~p"/agent-templates")}
        >
          <.header>{@page_title}</.header>

          <.simple_form
            for={@form}
            id="agent-template-form"
            phx-change="validate"
            phx-submit="save"
          >
            <%= if @live_action == :new do %>
              <.input
                field={@form[:slug]}
                type="text"
                label="Slug"
                placeholder="e.g. claude_code, codex, aider"
              />
            <% end %>
            <.input field={@form[:name]} type="text" label="Name" />
            <.input
              field={@form[:executable]}
              type="text"
              label="Executable"
              placeholder="claude"
            />
            <.input
              field={@form[:command_prefix]}
              type="text"
              label="Command prefix"
              placeholder="docker run --rm -v {{project_path}}:/w -w /w img"
            />
            <p class="text-xs text-base-content/50 -mt-2">
              Optional. Prepended to the executable. Supports <code>{"{{project_path}}"}</code>. Whitespace-tokenized.
            </p>
            <.input
              field={@form[:base_args]}
              type="textarea"
              label="Base args (one per line)"
              rows="4"
            />
            <.input
              field={@form[:prompt_flag]}
              type="text"
              label="Prompt flag (blank for positional)"
              placeholder="-p"
            />
            <.input
              field={@form[:tools_flag]}
              type="text"
              label="Allowed-tools flag (blank to disable)"
              placeholder="--allowedTools"
            />
            <.input
              field={@form[:tools_separator]}
              type="text"
              label="Tools separator"
            />
            <.input
              field={@form[:permission_args_by_stage]}
              type="textarea"
              label="Permission args by stage (JSON)"
              rows="5"
            />
            <p class="text-xs text-base-content/50 -mt-2">
              Map of task stage to extra CLI args, e.g. <code>{"{\"planning\": [\"--permission-mode\", \"plan\"]}"}</code>.
            </p>
            <.input
              field={@form[:internal_tools]}
              type="textarea"
              label="Internal tools (one per line)"
              rows="3"
            />
            <.input
              field={@form[:env_vars]}
              type="textarea"
              label="Environment variables (JSON object)"
              rows="3"
            />
            <.input
              field={@form[:parser]}
              type="select"
              label="Output parser"
              options={@parser_options}
            />
            <.input
              field={@form[:pr_url_pattern]}
              type="text"
              label="PR URL regex"
            />
            <.input
              field={@form[:question_phrases]}
              type="textarea"
              label="Question phrases (one per line)"
              rows="4"
            />
            <.input
              field={@form[:base_retry_delay_ms]}
              type="number"
              label="Base retry delay (ms)"
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
        <.table id="agent-templates" rows={@templates}>
          <:col :let={template} label="Slug">
            <code>{template.slug}</code>
          </:col>
          <:col :let={template} label="Name">{template.name}</:col>
          <:col :let={template} label="Executable">
            <code class="text-xs">{template.executable}</code>
          </:col>
          <:col :let={template} label="Parser">
            <span class="badge badge-ghost">{template.parser}</span>
          </:col>
          <:col :let={template} label="Prefix">
            <code :if={template.command_prefix} class="text-xs">
              {template.command_prefix}
            </code>
            <span :if={!template.command_prefix} class="text-base-content/40">—</span>
          </:col>
          <:action :let={template}>
            <.link navigate={~p"/agent-templates/#{template.id}/edit"}>
              Edit
            </.link>
          </:action>
          <:action :let={template}>
            <.link
              phx-click={JS.push("delete", value: %{id: template.id})}
              data-confirm="Delete this template?"
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
