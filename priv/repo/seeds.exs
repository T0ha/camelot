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

alias Camelot.Agents.Agent
alias Camelot.Agents.ClaudeCodeDefaults
alias Camelot.Agents.CodexDefaults
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

existing_templates = Ash.read!(Agent)

# Planning delivers a machine-readable decision via the CLI's
# `--json-schema` structured-output contract (see
# `Camelot.Agents.ClaudeCodeDefaults` and
# docs/planning-output-contract.md). The runner's Claude Code
# (ToolSearch build) does NOT expose ExitPlanMode in the headless tool
# registry, so the plan/question can't be recovered from a tool denial;
# instead the agent emits it via the injected `StructuredOutput` tool.
claude_code_available_models = [
  "claude-opus-5",
  "claude-sonnet-5",
  "claude-haiku-4-5-20251001"
]

claude_code_attrs = %{
  name: "Claude Code",
  executable: "claude",
  base_args: ["--output-format", "stream-json", "--verbose"],
  prompt_flag: "-p",
  tools_flag: "--allowedTools",
  model_flag: "--model",
  available_models: claude_code_available_models,
  default_model: "claude-sonnet-5",
  tools_separator: ",",
  permission_args_by_stage: ClaudeCodeDefaults.permission_args_by_stage(),
  internal_tools: ["EnterPlanMode", "ExitPlanMode"],
  env_vars: %{"CLAUDECODE" => "false"},
  parser: :claude_code_json,
  pr_url_pattern: pr_url_pattern,
  question_phrases: question_phrases,
  base_retry_delay_ms: 5_000,
  max_retries: 3
}

case Enum.find(existing_templates, &(&1.slug == "claude_code")) do
  nil ->
    Ash.create!(Agent, Map.put(claude_code_attrs, :slug, "claude_code"))

  template ->
    # Reconcile existing installs onto the structured-output contract.
    Ash.update!(template, claude_code_attrs)
end

# Codex is configured against the modern CLI (`codex exec`), which has
# no `--quiet` flag and no `--append-system-prompt` equivalent — see
# `Camelot.Agents.CodexDefaults`. Reconciled rather than
# create-if-missing, same as `claude_code` above, so an install seeded
# against the old CLI is repaired instead of left broken.
codex_attrs = %{
  name: "Codex",
  executable: "codex",
  base_args: CodexDefaults.base_args(),
  # `available_models`/`default_model` deliberately left unset: unlike
  # Claude Code's ids above, Codex CLI's current `--model` values
  # aren't confirmed here. Left for an admin to fill in via the Agent
  # CLI admin page once verified against the CLI's own docs.
  model_flag: "--model",
  tools_separator: ",",
  permission_args_by_stage: CodexDefaults.permission_args_by_stage(),
  system_prompt_by_stage: CodexDefaults.system_prompt_by_stage(),
  output_schema_by_stage: CodexDefaults.output_schema_by_stage(),
  parser: CodexDefaults.parser(),
  pr_url_pattern: pr_url_pattern,
  question_phrases: CodexDefaults.question_phrases(),
  runner_image: CodexDefaults.runner_image(),
  required_credential_kinds: [:codex_api_key],
  base_retry_delay_ms: 5_000,
  max_retries: 3
}

case Enum.find(existing_templates, &(&1.slug == "codex")) do
  nil ->
    Ash.create!(Agent, Map.put(codex_attrs, :slug, "codex"))

  template ->
    Ash.update!(template, codex_attrs)
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
