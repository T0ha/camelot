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
  alias Camelot.Projects.Project
  alias Camelot.Prompts.Renderer

  require Logger

  @placeholder ~r/^\{\{prompt:(.+)\}\}$/

  @enforce_keys [:parser, :executable]
  defstruct command_prefix: nil,
            executable: nil,
            base_args: [],
            prompt_flag: nil,
            tools_flag: nil,
            tools_separator: ",",
            permission_args_by_stage: %{},
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
          tools_separator: String.t(),
          permission_args_by_stage: %{optional(String.t()) => [String.t()]},
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
      tools_separator: agent.tools_separator,
      permission_args_by_stage:
        override(
          project.permission_args_by_stage_override,
          agent.permission_args_by_stage
        ),
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
  """
  @spec render_permission_args(t(), String.t() | nil, String.t() | nil) :: t()
  def render_permission_args(%__MODULE__{} = config, project_id, user_id) do
    rendered =
      Map.new(config.permission_args_by_stage, fn {stage, args} ->
        {stage, Enum.map(args, &render_arg(&1, project_id, user_id))}
      end)

    %{config | permission_args_by_stage: rendered}
  end

  @spec prefix_tokens(t(), String.t()) :: [String.t()]
  def prefix_tokens(%__MODULE__{command_prefix: nil}, _project_path), do: []

  def prefix_tokens(%__MODULE__{command_prefix: prefix}, project_path) do
    prefix
    |> String.replace("{{project_path}}", project_path)
    |> String.split(~r/\s+/, trim: true)
  end

  @spec build_cli_args(t(), String.t(), [String.t()], atom()) :: [String.t()]
  def build_cli_args(%__MODULE__{} = config, prompt, allowed_tools, task_stage) do
    config.base_args
    |> Kernel.++(stage_args(config, task_stage))
    |> Kernel.++(tools_args(config, allowed_tools))
    |> Kernel.++(prompt_args(config, prompt))
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
  # would silently strip e.g. "always open a PR" from every run) —
  # fall back to the built-in default and log loudly instead.
  defp fallback_for(slug) do
    Logger.warning("Missing PromptTemplate #{slug}; using built-in default")

    case slug do
      "claude_planning_system_prompt" -> ClaudeCodeDefaults.planning_system_prompt()
      "claude_execution_system_prompt" -> ClaudeCodeDefaults.execution_system_prompt()
      "claude_pr_system_prompt" -> ClaudeCodeDefaults.pr_system_prompt()
      _ -> ""
    end
  end

  defp tools_args(%__MODULE__{tools_flag: nil}, _tools), do: []

  defp tools_args(config, allowed_tools) do
    filtered = filter_internal_tools(allowed_tools, config.internal_tools)

    case filtered do
      [] -> []
      list -> [config.tools_flag, Enum.join(list, config.tools_separator)]
    end
  end

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
end
