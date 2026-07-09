# Script for populating the database. You can run it as:
#
#     mix run priv/repo/seeds.exs
#
# Inside the script, you can read and write to any of your
# repositories directly:
#
#     Camelot.Repo.insert!(%Camelot.SomeSchema{})
#
# We recommend using the bang functions (`insert!`, `update!`
# and so on) as they will fail if something goes wrong.

alias Camelot.Agents.AgentTemplate
alias Camelot.Agents.ClaudeCodeDefaults
alias Camelot.Prompts.PromptTemplate

pr_url_pattern = "https://github\\.com/[^\\s]+/pull/(\\d+)"

question_phrases = [
  "could you",
  "can you",
  "please provide",
  "please clarify",
  "please specify",
  "what would",
  "which approach",
  "do you want",
  "would you like",
  "waiting for",
  "need more information",
  "let me know"
]

existing_templates = Ash.read!(AgentTemplate)

# Planning delivers a machine-readable decision via the CLI's
# `--json-schema` structured-output contract (see
# `Camelot.Agents.ClaudeCodeDefaults` and
# docs/planning-output-contract.md). The runner's Claude Code
# (ToolSearch build) does NOT expose ExitPlanMode in the headless tool
# registry, so the plan/question can't be recovered from a tool denial;
# instead the agent emits it via the injected `StructuredOutput` tool.
claude_code_attrs = %{
  name: "Claude Code",
  executable: "claude",
  base_args: ["--output-format", "stream-json", "--verbose"],
  prompt_flag: "-p",
  tools_flag: "--allowedTools",
  tools_separator: ",",
  permission_args_by_stage: ClaudeCodeDefaults.permission_args_by_stage(),
  internal_tools: ["EnterPlanMode", "ExitPlanMode"],
  env_vars: %{"CLAUDECODE" => "false"},
  parser: :claude_code_json,
  pr_url_pattern: pr_url_pattern,
  question_phrases: question_phrases,
  base_retry_delay_ms: 5_000
}

case Enum.find(existing_templates, &(&1.slug == "claude_code")) do
  nil ->
    Ash.create!(AgentTemplate, Map.put(claude_code_attrs, :slug, "claude_code"))

  template ->
    # Reconcile existing installs onto the structured-output contract.
    Ash.update!(template, claude_code_attrs)
end

if !Enum.any?(existing_templates, &(&1.slug == "codex")) do
  Ash.create!(AgentTemplate, %{
    slug: "codex",
    name: "Codex",
    executable: "codex",
    base_args: ["--quiet"],
    tools_separator: ",",
    parser: :raw_text,
    pr_url_pattern: pr_url_pattern,
    base_retry_delay_ms: 5_000
  })
end

existing = Ash.read!(PromptTemplate)

if !Enum.any?(existing, &(&1.slug == "planning" and is_nil(&1.project_id))) do
  Ash.create!(PromptTemplate, %{
    slug: "planning",
    name: "Planning Prompt",
    body: "Task: {{title}}\nDescription: {{description}}"
  })
end

if !Enum.any?(existing, &(&1.slug == "execution" and is_nil(&1.project_id))) do
  Ash.create!(PromptTemplate, %{
    slug: "execution",
    name: "Execution Prompt",
    body: "Task: {{title}}\nDescription: {{description}}\nPlan: {{plan}}"
  })
end
