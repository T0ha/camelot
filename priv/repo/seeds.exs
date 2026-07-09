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
# `--json-schema` structured-output contract. The runner's Claude Code
# (ToolSearch build) does NOT expose ExitPlanMode in the headless tool
# registry, so the plan/question can't be recovered from a tool denial;
# instead the agent must emit this object via the injected
# `StructuredOutput` tool, which the parser reads from the result event's
# `structured_output` field. See docs/planning-output-contract.md.
planning_schema =
  Jason.encode!(%{
    "type" => "object",
    "properties" => %{
      "decision" => %{
        "type" => "string",
        "enum" => ["plan", "question"],
        "description" =>
          ~s(Use "plan" when you have a complete implementation plan ) <>
            ~s(ready for approval. Use "question" when you need input, a ) <>
            ~s(decision, or clarification from the user before the plan ) <>
            ~s(can be finalized.)
      },
      "plan" => %{
        "type" => "string",
        "description" =>
          ~s(The full implementation plan in Markdown. Required when ) <>
            ~s(decision is "plan".)
      },
      "questions" => %{
        "type" => "array",
        "items" => %{"type" => "string"},
        "description" =>
          ~s(One clarifying question per item. Required when decision ) <>
            ~s(is "question".)
      }
    },
    "required" => ["decision"]
  })

planning_system_prompt =
  ~s(You are in planning mode: investigate the repository read-only, ) <>
    ~s(then deliver your result by calling the StructuredOutput tool. ) <>
    ~s(Set decision="plan" with a complete Markdown plan when you are ) <>
    ~s(ready for approval, or decision="question" with specific ) <>
    ~s(questions when you need input or a decision before planning can ) <>
    ~s(complete. Never ask questions as plain assistant text; always ) <>
    ~s(use StructuredOutput.)

claude_code_attrs = %{
  name: "Claude Code",
  executable: "claude",
  base_args: ["--output-format", "stream-json", "--verbose"],
  prompt_flag: "-p",
  tools_flag: "--allowedTools",
  tools_separator: ",",
  permission_args_by_stage: %{
    "planning" => [
      "--permission-mode",
      "plan",
      "--append-system-prompt",
      planning_system_prompt,
      "--json-schema",
      planning_schema
    ],
    "executing" => ["--permission-mode", "acceptEdits"]
  },
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
