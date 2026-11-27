defmodule Camelot.Agents.AntigravityDefaults do
  @moduledoc """
  Canonical CLI defaults for the built-in `antigravity` agent template,
  written against the Google Antigravity CLI (`agy` 1.4.x).

  Single source of truth shared by `priv/repo/seeds.exs`, the data
  migration that inserts the row, and the regression tests, so the
  three never drift — the same role `Camelot.Agents.ClaudeCodeDefaults`
  and `Camelot.Agents.CodexDefaults` play for their templates.

  The CLI sits between the other two:

    * like Claude Code it takes the prompt as the value of `-p`, emits
      line-delimited JSON under `--output-format stream-json`, and
      takes the planning schema inline via `--json-schema`;

    * like Codex it has no `--append-system-prompt` equivalent, so the
      per-stage system prompt is delivered by
      `Camelot.Runtime.AgentConfig` prepending
      `system_prompt_by_stage/0` to the prompt rather than as a flag.

  `--dangerously-skip-permissions` assumes the Swarm/DockerEngine
  runner, where the agent already runs in a throwaway container with
  no TTY to approve at. Running this template under the `LocalPort`
  backend gives `agy` unprompted access to the developer's own
  checkout — override `permission_args_by_stage` per project (or per
  agent, at `/agents`) to tighten that.
  """

  @base_args ["--output-format", "stream-json"]

  @doc """
  Static args prepended to every run.

  `--output-format stream-json` switches the run onto the
  line-delimited event stream the `:antigravity_json` parser reads,
  ending in a single `{"event": "result", ...}` object.
  """
  @spec base_args() :: [String.t()]
  def base_args, do: @base_args

  @doc "Flag carrying the non-interactive prompt."
  @spec prompt_flag() :: String.t()
  def prompt_flag, do: "-p"

  @doc "Flag selecting the model."
  @spec model_flag() :: String.t()
  def model_flag, do: "--model"

  @available_models [
    "gemini-3.8-flash-high",
    "gemini-3.8-flash-medium",
    "gemini-3.8-flash-low",
    "claude-sonnet-4-6",
    "claude-opus-4-6-thinking",
    "gpt-oss-120b-medium"
  ]

  @doc """
  Model ids the CLI's `--model` flag accepts, as listed by `agy` 1.4.2.

  This is the **offline fallback**: `Camelot.Agents.ModelDiscovery`
  asks Google what the task creator's own key may use (see
  `models_probe/0`) and supersedes it whenever it gets an answer.
  """
  @spec available_models() :: [String.t()]
  def available_models, do: @available_models

  @doc "Model pinned when a task does not pick one."
  @spec default_model() :: String.t()
  def default_model, do: "gemini-3.8-flash-high"

  @models_probe %{
    "strategy" => "http_models_endpoint",
    "url" => "https://generativelanguage.googleapis.com/v1beta/models",
    "auth" => "google",
    "credential_kind" => "gemini_api_key",
    "list_key" => "models",
    "id_key" => "name",
    "strip_prefix" => "models/",
    "include" => "^gemini-"
  }

  @doc """
  Probe config for live, per-user model discovery — see
  `Camelot.Agents.ModelDiscovery`.

  Google's `GET /v1beta/models` lists the models under a `models` key
  and names each one `models/<id>`, hence `strip_prefix`. The listing
  includes embedding and other non-chat models, so `include` keeps it
  to the Gemini family.
  """
  @spec models_probe() :: map()
  def models_probe, do: @models_probe

  @doc """
  Credential kinds that satisfy this CLI's auth.

  `:gemini_api_key`, which `Camelot.Runtime.Runner.SecretEnv` mounts
  as both `GEMINI_API_KEY` and `GOOGLE_API_KEY` — the CLI reads either.
  A runner container has no browser login, so an API key is the only
  option.
  """
  @spec required_credential_kinds() :: [atom()]
  def required_credential_kinds, do: [:gemini_api_key]

  @doc """
  Image carrying the `agy` binary (`runner-images/agy/Dockerfile`).

  A nil `runner_image` resolves to `alpine:latest` in the Swarm and
  DockerEngine backends, which has no `agy` at all.
  """
  @spec runner_image() :: String.t()
  def runner_image, do: "ghcr.io/t0ha/camelot-runner-agy:latest"

  @planning_system_prompt "You are in planning mode: investigate the " <>
                            "repository read-only and do not modify, " <>
                            "create, or delete any file. Your final answer " <>
                            "is validated against a JSON Schema. Set " <>
                            ~s(decision="plan" with the complete ) <>
                            "implementation plan in Markdown under `plan` " <>
                            "when you are ready for approval, or " <>
                            ~s(decision="question" with specific questions ) <>
                            "under `questions` when you need input or a " <>
                            "decision before planning can complete."

  @doc "Literal default system prompt for the planning run."
  @spec planning_system_prompt() :: String.t()
  def planning_system_prompt, do: @planning_system_prompt

  @doc "Slug of the `PromptTemplate` row holding the planning system prompt."
  @spec planning_system_prompt_slug() :: String.t()
  def planning_system_prompt_slug, do: "agy_planning_system_prompt"

  @execution_system_prompt "You are running fully autonomously in a " <>
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

  @doc "Literal default system prompt for the execution run."
  @spec execution_system_prompt() :: String.t()
  def execution_system_prompt, do: @execution_system_prompt

  @doc "Slug of the `PromptTemplate` row holding the execution system prompt."
  @spec execution_system_prompt_slug() :: String.t()
  def execution_system_prompt_slug, do: "agy_execution_system_prompt"

  @pr_system_prompt "You are addressing review feedback and CI failures on " <>
                      "an existing pull request, autonomously and in a " <>
                      "single turn. Push your fixes to the pull request's " <>
                      "own branch — do not open a second pull request — and " <>
                      "print the pull request URL as the last line of your " <>
                      "final message."

  @doc "Literal default system prompt for the pr-review run."
  @spec pr_system_prompt() :: String.t()
  def pr_system_prompt, do: @pr_system_prompt

  @doc "Slug of the `PromptTemplate` row holding the pr-review system prompt."
  @spec pr_system_prompt_slug() :: String.t()
  def pr_system_prompt_slug, do: "agy_pr_system_prompt"

  @doc """
  JSON Schema (encoded string) passed inline as `--json-schema` for
  planning. The result event then carries the validated object under
  `structured_output`, which `Camelot.Runtime.OutputParser` surfaces
  as `structured` — the contract described in
  `docs/planning-output-contract.md`.
  """
  @spec planning_json_schema() :: String.t()
  def planning_json_schema do
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
  end

  @doc """
  Per-stage mode/permission args for the `antigravity` template.

  Planning runs in `--mode plan` with the inline planning schema;
  executing and pr need to write files, run builds, and push, so they
  run in `--mode accept-edits`. Every stage carries
  `--dangerously-skip-permissions` because there is no TTY to approve
  a tool request at.
  """
  @spec permission_args_by_stage() :: %{optional(String.t()) => [String.t()]}
  def permission_args_by_stage do
    %{
      "planning" => [
        "--mode",
        "plan",
        "--dangerously-skip-permissions",
        "--json-schema",
        planning_json_schema()
      ],
      "executing" => [
        "--mode",
        "accept-edits",
        "--dangerously-skip-permissions"
      ],
      "pr" => ["--mode", "accept-edits", "--dangerously-skip-permissions"]
    }
  end

  @doc """
  Per-stage system prompts as `{{prompt:<slug>}}` placeholders,
  resolved at dispatch time by
  `Camelot.Runtime.AgentConfig.render_system_prompts/3` against the
  `PromptTemplate` rows named by the `*_system_prompt_slug/0`
  functions above, then prepended to the prompt.
  """
  @spec system_prompt_by_stage() :: %{optional(String.t()) => String.t()}
  def system_prompt_by_stage do
    %{
      "planning" => "{{prompt:#{planning_system_prompt_slug()}}}",
      "executing" => "{{prompt:#{execution_system_prompt_slug()}}}",
      "pr" => "{{prompt:#{pr_system_prompt_slug()}}}"
    }
  end

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

  @doc """
  Phrases marking planning output as a clarifying question — the
  fallback for a run whose structured decision is missing.
  """
  @spec question_phrases() :: [String.t()]
  def question_phrases, do: @question_phrases

  @doc """
  Output parser for this CLI: the `--output-format stream-json` event
  stream. See `Camelot.Runtime.OutputParser`.
  """
  @spec parser() :: :antigravity_json
  def parser, do: :antigravity_json
end
