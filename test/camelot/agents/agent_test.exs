defmodule Camelot.Agents.AgentTest do
  use Camelot.DataCase, async: true

  alias Camelot.Agents.Agent
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
    end

    test "codex agent exists with raw_text parser" do
      agent = agent!("codex")

      assert agent.name == "Codex"
      assert agent.parser == :raw_text
      assert agent.base_args == ["--quiet"]
      assert agent.prompt_flag == nil
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
