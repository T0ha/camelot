defmodule CamelotWeb.AgentLive.Index do
  @moduledoc """
  LiveView for managing Agent (CLI template) rows.

  Array fields (base_args, internal_tools, question_phrases)
  are edited as one-entry-per-line textareas. Map fields
  (permission_args_by_stage, env_vars) are edited as JSON
  textareas and validated on save.
  """
  use CamelotWeb, :live_view

  alias Camelot.Agents.Agent

  @parser_options [
    {"Claude Code JSON", "claude_code_json"},
    {"Raw Text", "raw_text"}
  ]

  @text_fields ~w(slug name command_prefix executable prompt_flag
                  tools_flag tools_separator parser pr_url_pattern
                  runner_image)
  @array_fields ~w(base_args internal_tools question_phrases
                   required_credential_kinds)
  @map_fields ~w(permission_args_by_stage env_vars runner_resources)
  @integer_fields ~w(base_retry_delay_ms max_retries)

  @credential_kinds ~w(claude_api_key openai_api_key codex_api_key
                       ssh_private_key generic)

  @impl true
  def mount(_params, _session, socket) do
    {:ok, load_agents(socket)}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    assign(socket, page_title: "Agent CLI", agent: nil)
  end

  defp apply_action(socket, :new, _params) do
    assign(socket,
      page_title: "New Agent CLI",
      agent: nil,
      form: to_form(blank_form()),
      parser_options: @parser_options,
      credential_kinds: @credential_kinds
    )
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    agent = Ash.get!(Agent, id)

    assign(socket,
      page_title: "Edit Agent CLI",
      agent: agent,
      form: to_form(agent_to_form(agent)),
      parser_options: @parser_options,
      credential_kinds: @credential_kinds
    )
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    agent = Ash.get!(Agent, id)
    Ash.destroy!(agent)

    {:noreply,
     socket
     |> put_flash(:info, "Agent CLI deleted")
     |> load_agents()}
  end

  def handle_event("validate", params, socket) do
    {:noreply, assign(socket, form: to_form(form_params(params)))}
  end

  def handle_event("save", params, socket) do
    form_p = form_params(params)

    case build_attrs(form_p) do
      {:ok, attrs} ->
        save_agent(socket, socket.assigns.live_action, attrs, form_p)

      {:error, msg} ->
        {:noreply,
         socket
         |> put_flash(:error, msg)
         |> assign(form: to_form(form_p))}
    end
  end

  defp save_agent(socket, :new, attrs, form_p) do
    case Ash.create(Agent, attrs, action: :create) do
      {:ok, _agent} ->
        {:noreply,
         socket
         |> put_flash(:info, "Agent CLI created")
         |> push_navigate(to: ~p"/agents")}

      {:error, error} ->
        {:noreply,
         socket
         |> put_flash(:error, "Failed to create agent CLI: #{format_error(error)}")
         |> assign(form: to_form(form_p))}
    end
  end

  defp save_agent(socket, :edit, attrs, form_p) do
    attrs = Map.delete(attrs, :slug)

    case Ash.update(socket.assigns.agent, attrs, action: :update) do
      {:ok, _agent} ->
        {:noreply,
         socket
         |> put_flash(:info, "Agent CLI updated")
         |> push_navigate(to: ~p"/agents")}

      {:error, error} ->
        {:noreply,
         socket
         |> put_flash(:error, "Failed to update agent CLI: #{format_error(error)}")
         |> assign(form: to_form(form_p))}
    end
  end

  defp format_error(%Ash.Error.Invalid{errors: errors}) when is_list(errors) do
    Enum.map_join(errors, "; ", &format_one_error/1)
  end

  defp format_error(other), do: inspect(other, limit: :infinity, printable_limit: 4_000)

  defp format_one_error(%{field: field, message: msg}) when not is_nil(field), do: "#{field}: #{msg}"

  defp format_one_error(%{message: msg}) when is_binary(msg), do: msg
  defp format_one_error(other), do: inspect(other)

  defp load_agents(socket) do
    agents = Ash.read!(Agent)
    assign(socket, agents: Enum.sort_by(agents, & &1.slug))
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
      "base_retry_delay_ms" => "5000",
      "max_retries" => "3",
      "runner_image" => "",
      "runner_resources" => "{}",
      "required_credential_kinds" => ""
    }
  end

  defp agent_to_form(agent) do
    %{
      "slug" => agent.slug,
      "name" => agent.name,
      "command_prefix" => agent.command_prefix || "",
      "executable" => agent.executable,
      "base_args" => lines(agent.base_args),
      "prompt_flag" => agent.prompt_flag || "",
      "tools_flag" => agent.tools_flag || "",
      "tools_separator" => agent.tools_separator,
      "permission_args_by_stage" => Jason.encode!(agent.permission_args_by_stage, pretty: true),
      "internal_tools" => lines(agent.internal_tools),
      "env_vars" => Jason.encode!(agent.env_vars, pretty: true),
      "parser" => to_string(agent.parser),
      "pr_url_pattern" => agent.pr_url_pattern,
      "question_phrases" => lines(agent.question_phrases),
      "base_retry_delay_ms" => to_string(agent.base_retry_delay_ms),
      "max_retries" => to_string(agent.max_retries),
      "runner_image" => agent.runner_image || "",
      "runner_resources" => Jason.encode!(agent.runner_resources, pretty: true),
      "required_credential_kinds" => Enum.map_join(agent.required_credential_kinds, "\n", &Atom.to_string/1)
    }
  end

  defp form_params(params) do
    fields = @text_fields ++ @array_fields ++ @map_fields ++ @integer_fields
    Map.take(params, fields)
  end

  defp build_attrs(form_p) do
    with {:ok, perm} <- parse_json_map(form_p, "permission_args_by_stage"),
         {:ok, env} <- parse_json_map(form_p, "env_vars"),
         {:ok, resources} <- parse_json_map(form_p, "runner_resources"),
         {:ok, retry_ms} <- parse_int(form_p, "base_retry_delay_ms"),
         {:ok, max_retries} <- parse_int(form_p, "max_retries"),
         {:ok, kinds} <- parse_credential_kinds(form_p["required_credential_kinds"]) do
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
         base_retry_delay_ms: retry_ms,
         max_retries: max_retries,
         runner_image: nilify(form_p["runner_image"]),
         runner_resources: resources,
         required_credential_kinds: kinds
       }}
    end
  end

  defp parse_credential_kinds(text) do
    items = split_lines(text)
    invalid = Enum.reject(items, &(&1 in @credential_kinds))

    case invalid do
      [] -> {:ok, Enum.map(items, &String.to_existing_atom/1)}
      bad -> {:error, "unknown credential kinds: #{Enum.join(bad, ", ")}"}
    end
  end

  defp parse_json_map(form_p, key) do
    case Jason.decode(form_p[key] || "{}") do
      {:ok, %{} = map} -> {:ok, map}
      {:ok, _} -> {:error, "#{key} must be a JSON object"}
      {:error, _} -> {:error, "#{key} is not valid JSON"}
    end
  end

  defp parse_int(form_p, "max_retries" = key) do
    case Integer.parse(form_p[key] || "") do
      {n, ""} when n >= 0 -> {:ok, n}
      _ -> {:error, "#{key} must be a non-negative integer"}
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
        <h1 class="text-2xl font-bold">Agent CLI</h1>
        <.link
          navigate={~p"/agents/new"}
          class="btn btn-primary"
        >
          New Agent CLI
        </.link>
      </div>

      <%= if @live_action in [:new, :edit] do %>
        <.modal
          id="agent-modal"
          show
          on_cancel={JS.navigate(~p"/agents")}
        >
          <.header>{@page_title}</.header>

          <.simple_form
            for={@form}
            id="agent-form"
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
            <.input
              field={@form[:max_retries]}
              type="number"
              min="0"
              label="Max retries"
            />
            <p class="text-xs text-base-content/50 -mt-2">
              How many times to re-dispatch after a failed run. 0 disables retries.
            </p>

            <hr class="my-2 border-base-content/20" />
            <p class="text-sm font-semibold">
              Container runner (Swarm / DockerEngine)
            </p>
            <p class="text-xs text-base-content/50 -mt-2">
              Leave blank when using the LocalPort backend.
            </p>

            <.input
              field={@form[:runner_image]}
              type="text"
              label="Runner image"
              placeholder="ghcr.io/t0ha/camelot-runner-claude:latest"
            />
            <.input
              field={@form[:runner_resources]}
              type="textarea"
              label="Runner resource reservations (JSON)"
              rows="3"
            />
            <p class="text-xs text-base-content/50 -mt-2">
              Example: <code>{~s({"cpu": "1.0", "memory": "2G"})}</code>. Empty <code>{"{}"}</code>
              means no reservation.
            </p>
            <.input
              field={@form[:required_credential_kinds]}
              type="textarea"
              label="Required credential kinds (one per line)"
              rows="3"
            />
            <p class="text-xs text-base-content/50 -mt-2">
              Drives <code>SecretSync</code>. Valid kinds: {Enum.join(@credential_kinds, ", ")}.
            </p>

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
        <.table id="agents" rows={@agents}>
          <:col :let={agent} label="Slug">
            <code>{agent.slug}</code>
          </:col>
          <:col :let={agent} label="Name">{agent.name}</:col>
          <:col :let={agent} label="Executable">
            <code class="text-xs">{agent.executable}</code>
          </:col>
          <:col :let={agent} label="Parser">
            <span class="badge badge-ghost">{agent.parser}</span>
          </:col>
          <:col :let={agent} label="Max retries">{agent.max_retries}</:col>
          <:col :let={agent} label="Prefix">
            <code :if={agent.command_prefix} class="text-xs">
              {agent.command_prefix}
            </code>
            <span :if={!agent.command_prefix} class="text-base-content/40">—</span>
          </:col>
          <:action :let={agent}>
            <.link navigate={~p"/agents/#{agent.id}/edit"}>
              Edit
            </.link>
          </:action>
          <:action :let={agent}>
            <.link
              phx-click={JS.push("delete", value: %{id: agent.id})}
              data-confirm="Delete this agent CLI?"
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
