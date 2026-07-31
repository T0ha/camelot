defmodule Camelot.Agents.AgentTemplateTest do
  use Camelot.DataCase, async: true

  alias Camelot.Agents.AgentTemplate
  alias Ecto.Adapters.SQL

  describe "seeded data" do
    test "claude_code template exists with expected fields" do
      template = agent_template!("claude_code")

      assert template.name == "Claude Code"
      assert template.executable == "claude"
      assert template.base_args == ["--output-format", "stream-json", "--verbose"]
      assert template.prompt_flag == "-p"
      assert template.tools_flag == "--allowedTools"
      assert template.parser == :claude_code_json
      assert "EnterPlanMode" in template.internal_tools
      assert "ExitPlanMode" in template.internal_tools
      assert template.env_vars == %{"CLAUDECODE" => "false"}
    end

    test "codex template exists with raw_text parser" do
      template = agent_template!("codex")

      assert template.name == "Codex"
      assert template.parser == :raw_text
      assert template.base_args == ["--quiet"]
      assert template.prompt_flag == nil
    end
  end

  describe "create" do
    test "creates a custom template" do
      assert {:ok, template} =
               Ash.create(AgentTemplate, %{
                 slug: "aider",
                 name: "Aider",
                 executable: "aider",
                 base_args: ["--no-stream"],
                 parser: :raw_text
               })

      assert template.slug == "aider"
      assert template.tools_separator == ","
      assert template.base_retry_delay_ms == 5_000
    end

    test "enforces unique slug" do
      assert {:error, _} =
               Ash.create(AgentTemplate, %{
                 slug: "claude_code",
                 name: "Dup",
                 executable: "x"
               })
    end

    test "rejects unknown parser" do
      assert {:error, _} =
               Ash.create(AgentTemplate, %{
                 slug: "weird",
                 name: "Weird",
                 executable: "weird",
                 parser: :not_a_parser
               })
    end
  end

  describe "update" do
    test "edits CLI args without changing slug" do
      template = agent_template!("codex")

      assert {:ok, updated} =
               Ash.update(template, %{
                 base_args: ["--quiet", "--no-color"]
               })

      assert updated.base_args == ["--quiet", "--no-color"]
      assert updated.slug == "codex"
    end
  end

  describe "required_credential_kinds legacy values" do
    test "loads a row carrying a retired kind, dropping it instead of failing" do
      template = agent_template!("claude_code")

      # Simulate data left behind by a credential-kind retirement (e.g.
      # PR #75 removing github_pat/github_oauth) without a cleanup
      # migration having run yet: a raw SQL write, bypassing Ash, since
      # `String.to_existing_atom("github_pat")` no longer succeeds and
      # Ash's own `one_of`-validated write path would reject it outright.
      SQL.query!(
        Camelot.Repo,
        "UPDATE agent_templates SET required_credential_kinds = $1 WHERE id = $2",
        [["claude_api_key", "github_pat"], Ecto.UUID.dump!(template.id)]
      )

      reloaded = agent_template!("claude_code")

      assert reloaded.required_credential_kinds == [:claude_api_key]
    end
  end
end
