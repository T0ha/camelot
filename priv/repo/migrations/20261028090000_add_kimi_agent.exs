defmodule Camelot.Repo.Migrations.AddKimiAgent do
  @moduledoc """
  Adds the built-in `kimi` agent row (Kimi Code CLI 2.3.0) and its
  three stage system prompt templates to existing installs.

  Values are frozen literals rather than calls into
  `Camelot.Agents.KimiDefaults`, following
  `20260922060000_fix_codex_for_modern_cli.exs`: this migration's
  effect must not change if those defaults are edited later.

  Idempotent and safe for a hand-customised install:

    * the agent row inserts with `ON CONFLICT (slug) DO NOTHING`, so a
      `kimi` row someone created by hand at `/agents` is left alone;

    * the `PromptTemplate` rows insert under `WHERE NOT EXISTS`, and
      `down` only deletes a row whose body (or, for the agent, whose
      `base_args`) still matches what `up` wrote — and never an agent
      row that tasks or sessions already reference.

  No schema change is needed for the new `:kimi_jsonl` parser or
  `:kimi_api_key` credential kind: both columns are plain text,
  constrained only in Ash.
  """

  use Ecto.Migration

  @base_args ["--output-format", "stream-json"]

  @available_models [
    "kimi-code/k3",
    "kimi-code/k3.1-pro",
    "kimi-code/k3.1-pro-highspeed",
    "kimi-code/k3-256k",
    "kimi-code/kimi-for-coding",
    "kimi-code/kimi-for-coding-highspeed"
  ]

  @models_probe %{
    "strategy" => "http_models_endpoint",
    "candidates" => [
      "https://api.kimi.ai/coding/v1/models",
      "https://api.moonshot.ai/v1/models",
      "https://api.kimi.com/coding/v1/models",
      "https://api.moonshot.cn/v1/models"
    ],
    "auth" => "bearer",
    "credential_kind" => "kimi_api_key",
    "list_key" => "data",
    "id_key" => "id",
    "include" => "^(k\\d|kimi)",
    "id_prefix" => "kimi-code/"
  }

  @permission_args %{
    "planning" => ["--agent-file", "/opt/agent-cli/kimi/planning-agent.md"],
    "executing" => [],
    "pr" => []
  }

  @system_prompts %{
    "planning" => "{{prompt:kimi_planning_system_prompt}}",
    "executing" => "{{prompt:kimi_execution_system_prompt}}",
    "pr" => "{{prompt:kimi_pr_system_prompt}}"
  }

  @env_vars %{
    "KIMI_CODE_TRUST_WORKSPACE" => "1",
    "KIMI_CODE_NO_AUTO_UPDATE" => "1",
    "KIMI_DISABLE_TELEMETRY" => "1"
  }

  @question_phrases [
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

  @pr_url_pattern "https://github\\.com/[^\\s]+/pull/(\\d+)"

  @runner_image "ghcr.io/t0ha/camelot-runner-kimi:latest"

  @planning_body "You are in planning mode: investigate the " <>
                   "repository read-only and do not modify, " <>
                   "create, or delete any file. Answer with ONLY " <>
                   "a JSON object as your final message — no " <>
                   "prose, no code fences. Its shape is " <>
                   ~s({"decision": "plan" | "question", ) <>
                   ~s("plan": string | null, ) <>
                   ~s("questions": [string] | null}. Set ) <>
                   ~s("decision" to "plan" with the complete ) <>
                   "implementation plan in Markdown under " <>
                   ~s("plan" when you are ready for approval, or ) <>
                   ~s(to "question" with specific questions under ) <>
                   ~s("questions" when you need input or a ) <>
                   "decision before planning can complete. Set " <>
                   "the field you are not using to null."

  @execution_body "You are running fully autonomously in a " <>
                    "headless, single-turn session: there is no " <>
                    "interactive user to answer you and no follow-up " <>
                    "turn, so you must complete the whole task before " <>
                    "your turn ends. Do NOT run any command in the " <>
                    "background; run every command (tests, builds, " <>
                    "git) synchronously and wait for it to finish " <>
                    "inline. Do NOT stop to wait for a notification, " <>
                    "approval, or confirmation — the plan is already " <>
                    "approved. Finish the task by opening a pull " <>
                    "request with `gh pr create`, and print the " <>
                    "resulting PR URL as the last line of your final " <>
                    "message so it is captured."

  @pr_body "You are addressing review feedback and CI failures on " <>
             "an existing pull request, autonomously and in a " <>
             "single turn. Push your fixes to the pull request's " <>
             "own branch — do not open a second pull request — and " <>
             "print the pull request URL as the last line of your " <>
             "final message."

  @description "Prepended to the prompt — Kimi Code has no " <>
                 "--append-system-prompt flag."

  def up do
    seed_template("kimi_planning_system_prompt", "Kimi Planning System Prompt", @planning_body)

    seed_template(
      "kimi_execution_system_prompt",
      "Kimi Execution System Prompt",
      @execution_body
    )

    seed_template("kimi_pr_system_prompt", "Kimi PR Review System Prompt", @pr_body)

    repo().query!(
      """
      INSERT INTO agents (
        slug, name, executable, base_args, prompt_flag, model_flag,
        available_models, default_model, models_probe, tools_separator,
        permission_args_by_stage, system_prompt_by_stage,
        output_schema_by_stage, internal_tools, env_vars, parser,
        pr_url_pattern, question_phrases, base_retry_delay_ms,
        max_retries, runner_image, required_credential_kinds
      )
      VALUES (
        'kimi', 'Kimi Code', 'kimi', $1::text[], '-p', '-m',
        $2::text[], NULL, $3::text::jsonb, ',',
        $4::text::jsonb, $5::text::jsonb,
        '{}'::jsonb, ARRAY[]::text[], $6::text::jsonb, 'kimi_jsonl',
        $7, $8::text[], 5000,
        3, $9, ARRAY['kimi_api_key']::text[]
      )
      ON CONFLICT (slug) DO NOTHING
      """,
      [
        @base_args,
        @available_models,
        Jason.encode!(@models_probe),
        Jason.encode!(@permission_args),
        Jason.encode!(@system_prompts),
        Jason.encode!(@env_vars),
        @pr_url_pattern,
        @question_phrases,
        @runner_image
      ]
    )
  end

  def down do
    # A row tasks or sessions already point at stays: deleting it
    # would fail on their foreign keys.
    repo().query!(
      """
      DELETE FROM agents
       WHERE slug = 'kimi'
         AND base_args = $1::text[]
         AND NOT EXISTS (SELECT 1 FROM tasks WHERE agent_id = agents.id)
         AND NOT EXISTS (SELECT 1 FROM sessions WHERE agent_id = agents.id)
         AND NOT EXISTS (
           SELECT 1 FROM usage_policies WHERE agent_id = agents.id
         )
      """,
      [@base_args]
    )

    unseed_template("kimi_planning_system_prompt", @planning_body)
    unseed_template("kimi_execution_system_prompt", @execution_body)
    unseed_template("kimi_pr_system_prompt", @pr_body)
  end

  defp seed_template(slug, name, body) do
    repo().query!(
      """
      INSERT INTO prompt_templates (slug, name, body, description)
      SELECT $1, $2, $3, $4
       WHERE NOT EXISTS (
         SELECT 1 FROM prompt_templates
          WHERE slug = $1
            AND project_id IS NULL
            AND user_id IS NULL
       )
      """,
      [slug, name, body, @description]
    )
  end

  defp unseed_template(slug, seeded_body) do
    repo().query!(
      """
      DELETE FROM prompt_templates
       WHERE project_id IS NULL
         AND user_id IS NULL
         AND slug = $1
         AND body = $2
      """,
      [slug, seeded_body]
    )
  end
end
