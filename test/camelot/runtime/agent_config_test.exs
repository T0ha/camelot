defmodule Camelot.Runtime.AgentConfigTest do
  @moduledoc """
  Regression guard: the args produced from the seeded
  `claude_code` and `codex` agent CLIs must match exactly
  what the pre-migration hardcoded `TaskRunner.build_cli_args/4`
  emitted.
  """
  use Camelot.DataCase, async: true

  alias Camelot.Agents.ClaudeCodeDefaults
  alias Camelot.Projects.Project
  alias Camelot.Runtime.AgentConfig

  setup do
    %{
      claude: build_config("claude_code"),
      codex: build_config("codex")
    }
  end

  describe "build_cli_args/4 — claude_code parity with hardcoded logic" do
    test "planning stage emits the structured-output contract", ctx do
      args =
        AgentConfig.build_cli_args(
          ctx.claude,
          "do the thing",
          ["Read", "Write"],
          :planning
        )

      planning_args = ClaudeCodeDefaults.permission_args_by_stage()["planning"]

      assert args ==
               ["--output-format", "stream-json", "--verbose"] ++
                 planning_args ++
                 ["--allowedTools", "Read,Write", "-p", "do the thing"]

      # Guard the contract shape explicitly.
      assert "--permission-mode" in args
      assert "plan" in args
      assert "--json-schema" in args
    end

    test "executing stage emits acceptEdits + the execution system prompt", ctx do
      args =
        AgentConfig.build_cli_args(
          ctx.claude,
          "do it",
          ["Read"],
          :executing
        )

      executing_args = ClaudeCodeDefaults.permission_args_by_stage()["executing"]

      assert args ==
               ["--output-format", "stream-json", "--verbose"] ++
                 executing_args ++
                 ["--allowedTools", "Read", "-p", "do it"]

      # Guard the contract shape explicitly.
      assert "--permission-mode" in args
      assert "acceptEdits" in args
      assert "--append-system-prompt" in args
    end

    test "filters EnterPlanMode / ExitPlanMode from allowed_tools", ctx do
      args =
        AgentConfig.build_cli_args(
          ctx.claude,
          "p",
          ["Read", "EnterPlanMode", "ExitPlanMode", "Write"],
          :executing
        )

      assert "--allowedTools" in args
      assert "Read,Write" in args
    end

    test "omits --allowedTools when filtered list is empty", ctx do
      args =
        AgentConfig.build_cli_args(
          ctx.claude,
          "p",
          ["EnterPlanMode"],
          :executing
        )

      refute "--allowedTools" in args
    end

    test "filters parameterized tool names by base name", ctx do
      args =
        AgentConfig.build_cli_args(
          ctx.claude,
          "p",
          ["Read(foo)", "ExitPlanMode(bar)"],
          :executing
        )

      assert "Read(foo)" in args
      refute Enum.any?(args, &String.contains?(&1, "ExitPlanMode"))
    end
  end

  describe "build_cli_args/4 — codex parity" do
    test "uses positional prompt and --quiet base arg", ctx do
      args =
        AgentConfig.build_cli_args(
          ctx.codex,
          "hello",
          ["any", "tools"],
          :executing
        )

      assert args == ["--quiet", "hello"]
    end
  end

  describe "prefix_tokens/2" do
    test "returns [] when command_prefix is nil", ctx do
      assert AgentConfig.prefix_tokens(ctx.claude, "/tmp/x") == []
    end

    test "tokenizes on whitespace and substitutes {{project_path}}", ctx do
      config = %{
        ctx.claude
        | command_prefix: "docker run --rm -v {{project_path}}:/w -w /w img"
      }

      assert AgentConfig.prefix_tokens(config, "/tmp/proj") == [
               "docker",
               "run",
               "--rm",
               "-v",
               "/tmp/proj:/w",
               "-w",
               "/w",
               "img"
             ]
    end
  end

  describe "ClaudeCodeDefaults.execution_system_prompt/0" do
    test "forbids background tasks and mandates opening a PR" do
      prompt = ClaudeCodeDefaults.execution_system_prompt()

      assert prompt =~ "background task"
      assert prompt =~ "gh pr create"
      assert prompt =~ "PR URL"
    end
  end

  describe "resolve/2 — per-project overrides" do
    test "non-nil override wins over agent CLI default" do
      agent = agent_struct()

      project = %Project{
        path: "/p",
        base_retry_delay_ms_override: 500,
        executable_override: "claude-canary",
        env_vars_override: %{"FOO" => "bar"}
      }

      resolved = AgentConfig.resolve(agent, project)

      assert resolved.base_retry_delay_ms == 500
      assert resolved.executable == "claude-canary"
      assert resolved.env_vars == %{"FOO" => "bar"}
      assert resolved.base_args == agent.base_args
    end

    test "nil overrides fall back to agent CLI values" do
      resolved = AgentConfig.resolve(agent_struct(), %Project{path: "/p"})

      assert resolved.executable == "claude"
      assert resolved.base_retry_delay_ms == 5_000
      assert resolved.parser == :claude_code_json
    end
  end

  describe "resolve/2 — project-level runner_image override" do
    test "project override wins over agent CLI default" do
      agent = %{agent_struct() | runner_image: "ghcr.io/org/default:1.0"}
      project = %Project{path: "/p", runner_image_override: "ghcr.io/org/canary:1.0"}

      resolved = AgentConfig.resolve(agent, project)

      assert resolved.runner_image == "ghcr.io/org/canary:1.0"
    end

    test "nil project override falls back to the agent CLI's runner_image" do
      agent = %{agent_struct() | runner_image: "ghcr.io/org/default:1.0"}
      project = %Project{path: "/p", runner_image_override: nil}

      resolved = AgentConfig.resolve(agent, project)

      assert resolved.runner_image == "ghcr.io/org/default:1.0"
    end
  end

  describe "env_for_port/1" do
    test "renders env_vars as charlist tuples for Port", ctx do
      env = AgentConfig.env_for_port(ctx.claude)
      assert {~c"CLAUDECODE", ~c"false"} in env
    end
  end

  defp build_config(slug) do
    AgentConfig.resolve(agent!(slug), %Project{path: "/tmp/test"})
  end

  defp agent_struct do
    %Camelot.Agents.Agent{
      command_prefix: nil,
      executable: "claude",
      base_args: ["--output-format", "stream-json", "--verbose"],
      prompt_flag: "-p",
      tools_flag: "--allowedTools",
      tools_separator: ",",
      permission_args_by_stage: %{
        "planning" => ["--permission-mode", "plan"],
        "executing" => ["--permission-mode", "acceptEdits"]
      },
      internal_tools: ["EnterPlanMode", "ExitPlanMode"],
      env_vars: %{"CLAUDECODE" => "false"},
      parser: :claude_code_json,
      pr_url_pattern: "https://github\\.com/[^\\s]+/pull/(\\d+)",
      question_phrases: [],
      base_retry_delay_ms: 5_000
    }
  end
end
