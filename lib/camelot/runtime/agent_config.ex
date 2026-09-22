defmodule Camelot.Runtime.AgentConfig do
  @moduledoc """
  Resolves the effective CLI configuration for a task by
  merging its `Agent` (CLI template) defaults with any
  `Project` `*_override` fields, then builds the argv, env,
  and command-prefix tokens used by
  `Camelot.Runtime.TaskRunner` to open a Port.

  Override fields on the Project win over the agent CLI iff
  they are non-nil. Parser choice cannot be overridden
  per project (it implies a code-level contract).
  """

  alias Camelot.Agents.Agent
  alias Camelot.Agents.ClaudeCodeDefaults
  alias Camelot.Agents.CodexDefaults
  alias Camelot.Projects.Project
  alias Camelot.Prompts.Renderer

  require Logger

  @placeholder ~r/^\{\{prompt:([^}]+)\}\}$/
  @schema_path_placeholder "{{output_schema_path}}"

  @enforce_keys [:parser, :executable]
  defstruct command_prefix: nil,
            executable: nil,
            base_args: [],
            prompt_flag: nil,
            tools_flag: nil,
            model_flag: nil,
            tools_separator: ",",
            permission_args_by_stage: %{},
            system_prompt_by_stage: %{},
            output_schema_by_stage: %{},
            internal_tools: [],
            env_vars: %{},
            parser: :raw_text,
            pr_url_pattern: nil,
            question_phrases: [],
            base_retry_delay_ms: 5_000,
            runner_image: nil,
            runner_resources: %{},
            required_credential_kinds: []

  @type t :: %__MODULE__{
          command_prefix: String.t() | nil,
          executable: String.t(),
          base_args: [String.t()],
          prompt_flag: String.t() | nil,
          tools_flag: String.t() | nil,
          model_flag: String.t() | nil,
          tools_separator: String.t(),
          permission_args_by_stage: %{optional(String.t()) => [String.t()]},
          system_prompt_by_stage: %{optional(String.t()) => String.t()},
          output_schema_by_stage: %{optional(String.t()) => String.t()},
          internal_tools: [String.t()],
          env_vars: %{optional(String.t()) => String.t()},
          parser: :claude_code_json | :raw_text,
          pr_url_pattern: String.t() | nil,
          question_phrases: [String.t()],
          base_retry_delay_ms: pos_integer(),
          runner_image: String.t() | nil,
          runner_resources: %{optional(String.t()) => String.t()},
          required_credential_kinds: [atom()]
        }

  @spec resolve(Agent.t(), Project.t()) :: t()
  def resolve(%Agent{} = agent, %Project{} = project) do
    %__MODULE__{
      command_prefix: override(project.command_prefix_override, agent.command_prefix),
      executable: override(project.executable_override, agent.executable),
      base_args: override(project.base_args_override, agent.base_args),
      prompt_flag: agent.prompt_flag,
      tools_flag: agent.tools_flag,
      model_flag: agent.model_flag,
      tools_separator: agent.tools_separator,
      permission_args_by_stage:
        override(
          project.permission_args_by_stage_override,
          agent.permission_args_by_stage
        ),
      system_prompt_by_stage: agent.system_prompt_by_stage,
      output_schema_by_stage: agent.output_schema_by_stage,
      internal_tools: override(project.internal_tools_override, agent.internal_tools),
      env_vars: override(project.env_vars_override, agent.env_vars),
      parser: agent.parser,
      pr_url_pattern: agent.pr_url_pattern,
      question_phrases: agent.question_phrases,
      base_retry_delay_ms:
        override(
          project.base_retry_delay_ms_override,
          agent.base_retry_delay_ms
        ),
      runner_image: override(project.runner_image_override, agent.runner_image),
      runner_resources: agent.runner_resources,
      required_credential_kinds: agent.required_credential_kinds
    }
  end

  @doc """
  Resolves `{{prompt:<slug>}}` placeholders inside
  `config.permission_args_by_stage` against the `PromptTemplate`
  project → user → system-global resolution (see
  `Camelot.Prompts.Renderer.render/4`).

  Only touches `permission_args_by_stage` — never the task prompt or
  allowed-tools list, so a task's title/description text is never
  misinterpreted as a placeholder. Kept separate from `resolve/2` (DB-
  free) and `build_cli_args/4` (whose structural-equality regression
  tests must keep passing unmodified against the raw placeholder).

  The slug isn't restricted to the three built-in stage prompts — any
  `PromptTemplate` a user creates can be referenced this way, e.g. to
  experiment with alternate stage prompts without touching code.
  """
  @spec render_permission_args(t(), String.t() | nil, String.t() | nil) :: t()
  def render_permission_args(%__MODULE__{} = config, project_id, user_id) do
    rendered =
      Map.new(config.permission_args_by_stage, fn {stage, args} ->
        {stage, Enum.map(args, &render_arg(&1, project_id, user_id))}
      end)

    %{config | permission_args_by_stage: rendered}
  end

  @doc """
  Resolves `{{prompt:<slug>}}` placeholders inside
  `config.system_prompt_by_stage`, the same way
  `render_permission_args/3` does for the per-stage CLI args.

  Separate from that function because the two carry the system prompt
  for different kinds of CLI: one that takes it as a flag (Claude
  Code's `--append-system-prompt`) keeps it in
  `permission_args_by_stage`; one with no such flag (Codex) keeps it
  here, and `build_cli_args/5` prepends the resolved text to the
  prompt instead. A CLI only ever uses one of the two.
  """
  @spec render_system_prompts(t(), String.t() | nil, String.t() | nil) :: t()
  def render_system_prompts(%__MODULE__{} = config, project_id, user_id) do
    rendered =
      Map.new(config.system_prompt_by_stage, fn {stage, text} ->
        {stage, render_arg(to_string(text), project_id, user_id)}
      end)

    %{config | system_prompt_by_stage: rendered}
  end

  @doc """
  The JSON Schema this CLI should constrain `task_stage`'s final
  message to, or nil when the stage has none.

  `Camelot.Runtime.TaskRunner` hands it to the runner backend, which
  materialises it at `Runner.Spec.output_schema_path/1` — the path
  `resolve_output_schema_path/2` substitutes into the stage's args.
  """
  @spec output_schema(t(), atom()) :: String.t() | nil
  def output_schema(%__MODULE__{} = config, task_stage) do
    case Map.get(config.output_schema_by_stage, to_string(task_stage)) do
      schema when is_binary(schema) -> blank_to_nil(schema)
      _other -> nil
    end
  end

  @doc """
  Substitutes the `{{output_schema_path}}` placeholder in
  `permission_args_by_stage` with `path`.

  Kept separate from `render_permission_args/3` because the value
  isn't a `PromptTemplate` lookup but the per-session path the schema
  is written to, which only exists once a session id does.
  """
  @spec resolve_output_schema_path(t(), String.t()) :: t()
  def resolve_output_schema_path(%__MODULE__{} = config, path) do
    rendered =
      Map.new(config.permission_args_by_stage, fn {stage, args} ->
        {stage, Enum.map(args, &replace_schema_path(&1, path))}
      end)

    %{config | permission_args_by_stage: rendered}
  end

  defp replace_schema_path(@schema_path_placeholder, path), do: path
  defp replace_schema_path(arg, _path), do: arg

  defp blank_to_nil(schema) do
    case String.trim(schema) do
      "" -> nil
      _kept -> schema
    end
  end

  @spec prefix_tokens(t(), String.t()) :: [String.t()]
  def prefix_tokens(%__MODULE__{command_prefix: nil}, _project_path), do: []

  def prefix_tokens(%__MODULE__{command_prefix: prefix}, project_path) do
    prefix
    |> String.replace("{{project_path}}", project_path)
    |> String.split(~r/\s+/, trim: true)
  end

  @spec build_cli_args(t(), String.t(), [String.t()], atom(), String.t() | nil) ::
          [String.t()]
  def build_cli_args(%__MODULE__{} = config, prompt, allowed_tools, task_stage, model) do
    config.base_args
    |> Kernel.++(stage_args(config, task_stage))
    |> Kernel.++(tools_args(config, allowed_tools))
    |> Kernel.++(model_args(config, model))
    |> Kernel.++(prompt_args(config, with_system_prompt(config, prompt, task_stage)))
  end

  @spec env_for_port(t()) :: [{charlist(), charlist()}]
  def env_for_port(%__MODULE__{env_vars: env}) do
    Enum.map(env, fn {k, v} ->
      {to_charlist(k), to_charlist(v)}
    end)
  end

  @spec compile_pr_url_pattern(t()) :: Regex.t() | nil
  def compile_pr_url_pattern(%__MODULE__{pr_url_pattern: nil}), do: nil

  def compile_pr_url_pattern(%__MODULE__{pr_url_pattern: pattern}) do
    Regex.compile!(pattern)
  end

  defp override(nil, fallback), do: fallback
  defp override(value, _fallback), do: value

  defp stage_args(config, task_stage) do
    Map.get(config.permission_args_by_stage, to_string(task_stage), [])
  end

  defp render_arg(arg, project_id, user_id) do
    case Regex.run(@placeholder, arg) do
      [_, slug] -> render_prompt(slug, project_id, user_id)
      nil -> arg
    end
  end

  defp render_prompt(slug, project_id, user_id) do
    case Renderer.render(slug, project_id, user_id, %{}) do
      {:ok, body} -> body
      {:error, :template_not_found} -> fallback_for(slug)
    end
  end

  # A deleted/missing row must never blank out the system prompt (that
  # would silently strip e.g. "always open a PR" from every run) for a
  # built-in agent's three stages — fall back to the literal default
  # and log instead. Any other slug is a template a user created to
  # plug into `{{prompt:<slug>}}` themselves (e.g. to experiment with
  # an alternate stage prompt); there's no built-in text to restore
  # for those, so a missing row just renders empty, same as an
  # unfilled `claude_pr_system_prompt` row does today.
  defp fallback_for("claude_planning_system_prompt") do
    Logger.warning("Missing PromptTemplate claude_planning_system_prompt; using built-in default")
    ClaudeCodeDefaults.planning_system_prompt()
  end

  defp fallback_for("claude_execution_system_prompt") do
    Logger.warning("Missing PromptTemplate claude_execution_system_prompt; using built-in default")
    ClaudeCodeDefaults.execution_system_prompt()
  end

  defp fallback_for("claude_pr_system_prompt") do
    Logger.warning("Missing PromptTemplate claude_pr_system_prompt; using built-in default")
    ClaudeCodeDefaults.pr_system_prompt()
  end

  defp fallback_for("codex_planning_system_prompt") do
    Logger.warning("Missing PromptTemplate codex_planning_system_prompt; using built-in default")
    CodexDefaults.planning_system_prompt()
  end

  defp fallback_for("codex_execution_system_prompt") do
    Logger.warning("Missing PromptTemplate codex_execution_system_prompt; using built-in default")
    CodexDefaults.execution_system_prompt()
  end

  defp fallback_for("codex_pr_system_prompt") do
    Logger.warning("Missing PromptTemplate codex_pr_system_prompt; using built-in default")
    CodexDefaults.pr_system_prompt()
  end

  defp fallback_for(slug) do
    Logger.warning("Missing PromptTemplate #{slug}; using empty system prompt")
    ""
  end

  defp tools_args(%__MODULE__{tools_flag: nil}, _tools), do: []

  defp tools_args(config, allowed_tools) do
    filtered = filter_internal_tools(allowed_tools, config.internal_tools)

    case filtered do
      [] -> []
      list -> [config.tools_flag, Enum.join(list, config.tools_separator)]
    end
  end

  defp model_args(%__MODULE__{model_flag: nil}, _model), do: []
  defp model_args(_config, nil), do: []
  defp model_args(config, model), do: [config.model_flag, model]

  defp filter_internal_tools(allowed_tools, internal_tools) do
    Enum.reject(allowed_tools, fn tool ->
      base_name =
        tool
        |> String.split("(", parts: 2)
        |> List.first()

      base_name in internal_tools
    end)
  end

  defp prompt_args(%__MODULE__{prompt_flag: nil}, prompt), do: [prompt]
  defp prompt_args(%__MODULE__{prompt_flag: flag}, prompt), do: [flag, prompt]

  # A CLI with no append-system-prompt flag carries its stage system
  # prompt in `system_prompt_by_stage`; the only channel left to
  # deliver it is the prompt itself.
  defp with_system_prompt(config, prompt, task_stage) do
    config.system_prompt_by_stage
    |> Map.get(to_string(task_stage), "")
    |> to_string()
    |> String.trim()
    |> prefix_prompt(prompt)
  end

  defp prefix_prompt("", prompt), do: prompt
  defp prefix_prompt(system_prompt, prompt), do: system_prompt <> "\n\n" <> prompt
end
