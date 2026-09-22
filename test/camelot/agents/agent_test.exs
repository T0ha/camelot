defmodule Camelot.Agents.AgentTest do
  use Camelot.DataCase, async: true

  alias Camelot.Agents.Agent
  alias Camelot.Agents.CodexDefaults
  alias Ecto.Adapters.SQL

  describe "seeded data" do
    test "claude_code agent exists with expected fields" do
      agent = agent!("claude_code")

      assert agent.name == "Claude Code"
      assert agent.executable == "claude"
      assert agent.base_args == ["--output-format", "stream-json", "--verbose"]
      assert agent.prompt_flag == "-p"
      assert agent.tools_flag == "--allowedTools"
      assert agent.parser == :claude_code_json
      assert "EnterPlanMode" in agent.internal_tools
      assert "ExitPlanMode" in agent.internal_tools
      assert agent.env_vars == %{"CLAUDECODE" => "false"}
      assert agent.max_retries == 3
      assert agent.model_flag == "--model"
      assert "claude-sonnet-5" in agent.available_models
      assert agent.default_model == "claude-sonnet-5"
    end

    test "codex agent exists with raw_text parser" do
      agent = agent!("codex")

      assert agent.name == "Codex"
      assert agent.parser == CodexDefaults.parser()
      assert agent.base_args == CodexDefaults.base_args()
      assert agent.prompt_flag == nil
      assert agent.model_flag == "--model"
      assert agent.available_models == []
      assert agent.default_model == nil
    end

    test "codex agent is configured for the modern CLI" do
      agent = agent!("codex")

      # `codex exec`, not the removed `--quiet` of the CLI this row was
      # originally seeded against, which exited 2 before any model call.
      assert List.first(agent.base_args) == "exec"
      refute "--quiet" in agent.base_args

      # The JSONL event stream, not the human transcript: with
      # :raw_text the whole 122 KB run became the "plan".
      assert "--json" in agent.base_args
      assert agent.parser == :codex_jsonl

      # No --append-system-prompt equivalent: the stage system prompt
      # rides in on the prompt itself.
      assert agent.system_prompt_by_stage == CodexDefaults.system_prompt_by_stage()
      assert agent.permission_args_by_stage == CodexDefaults.permission_args_by_stage()

      # A nil runner_image resolves to alpine:latest, which has no codex.
      assert agent.runner_image == CodexDefaults.runner_image()
      assert agent.required_credential_kinds == [:codex_api_key]
    end
  end

  describe "create" do
    test "creates a custom agent" do
      assert {:ok, agent} =
               Ash.create(Agent, %{
                 slug: "aider",
                 name: "Aider",
                 executable: "aider",
                 base_args: ["--no-stream"],
                 parser: :raw_text
               })

      assert agent.slug == "aider"
      assert agent.tools_separator == ","
      assert agent.base_retry_delay_ms == 5_000
      assert agent.max_retries == 3
      assert agent.model_flag == nil
      assert agent.available_models == []
      assert agent.default_model == nil
    end

    test "creates a custom agent with model selection configured" do
      assert {:ok, agent} =
               Ash.create(Agent, %{
                 slug: "aider-models",
                 name: "Aider",
                 executable: "aider",
                 model_flag: "--model",
                 available_models: ["gpt-5.1", "claude-sonnet-5"],
                 default_model: "gpt-5.1"
               })

      assert agent.model_flag == "--model"
      assert agent.available_models == ["gpt-5.1", "claude-sonnet-5"]
      assert agent.default_model == "gpt-5.1"
    end

    test "creates a custom agent with an explicit max_retries" do
      assert {:ok, agent} =
               Ash.create(Agent, %{
                 slug: "no-retry",
                 name: "No Retry",
                 executable: "no-retry",
                 max_retries: 0
               })

      assert agent.max_retries == 0
    end

    test "enforces unique slug" do
      assert {:error, _} =
               Ash.create(Agent, %{
                 slug: "claude_code",
                 name: "Dup",
                 executable: "x"
               })
    end

    test "rejects unknown parser" do
      assert {:error, _} =
               Ash.create(Agent, %{
                 slug: "weird",
                 name: "Weird",
                 executable: "weird",
                 parser: :not_a_parser
               })
    end
  end

  describe "update" do
    test "edits CLI args without changing slug" do
      agent = agent!("codex")

      assert {:ok, updated} =
               Ash.update(agent, %{
                 base_args: ["--quiet", "--no-color"]
               })

      assert updated.base_args == ["--quiet", "--no-color"]
      assert updated.slug == "codex"
    end

    test "edits max_retries" do
      agent = agent!("codex")

      assert {:ok, updated} = Ash.update(agent, %{max_retries: 5})
      assert updated.max_retries == 5
    end

    test "edits model selection fields" do
      agent = agent!("codex")

      assert {:ok, updated} =
               Ash.update(agent, %{
                 model_flag: "--model",
                 available_models: ["o4-mini"],
                 default_model: "o4-mini"
               })

      assert updated.model_flag == "--model"
      assert updated.available_models == ["o4-mini"]
      assert updated.default_model == "o4-mini"
    end
  end

  describe "required_credential_kinds legacy values" do
    test "loads a row carrying a retired kind, dropping it instead of failing" do
      agent = agent!("claude_code")

      # Simulate data left behind by a credential-kind retirement (e.g.
      # PR #75 removing github_pat/github_oauth) without a cleanup
      # migration having run yet: a raw SQL write, bypassing Ash, since
      # `String.to_existing_atom("github_pat")` no longer succeeds and
      # Ash's own `one_of`-validated write path would reject it outright.
      SQL.query!(
        Camelot.Repo,
        "UPDATE agents SET required_credential_kinds = $1 WHERE id = $2",
        [["claude_api_key", "github_pat"], Ecto.UUID.dump!(agent.id)]
      )

      reloaded = agent!("claude_code")

      assert reloaded.required_credential_kinds == [:claude_api_key]
    end
  end
end
