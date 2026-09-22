defmodule Camelot.Agents.CodexDefaults do
  @moduledoc """
  Canonical CLI defaults for the built-in `codex` agent template,
  written against the modern Codex CLI (`codex exec`, 0.4x+).

  Single source of truth shared by `priv/repo/seeds.exs`, the data
  migration that repairs already-seeded rows, and the regression
  tests, so the three never drift — the same role
  `Camelot.Agents.ClaudeCodeDefaults` plays for `claude_code`.

  Two things differ from Claude Code and shape everything below:

    * Non-interactive runs live behind the `exec` subcommand. The
      original seed passed a bare `--quiet`, which the modern CLI
      rejects with exit 2 before any model call.

    * There is no `--append-system-prompt` equivalent, so the
      per-stage system prompt is delivered by
      `Camelot.Runtime.AgentConfig` prepending
      `system_prompt_by_stage/0` to the positional prompt rather
      than as a CLI flag.

  The executing/pr sandbox posture assumes the Swarm/DockerEngine
  runner, where the agent already runs inside a throwaway container:
  `--dangerously-bypass-approvals-and-sandbox` is the documented
  posture for an externally sandboxed environment, and it is what
  lets the agent write files and push a branch with no TTY to
  approve at. Running this template under the `LocalPort` backend
  therefore gives Codex unsandboxed access to the developer's own
  checkout — override `permission_args_by_stage` per project (or
  per agent, at `/agents`) to tighten that.
  """

  @base_args ["exec", "--json", "--skip-git-repo-check", "--color", "never"]

  @doc """
  Static args prepended to every run.

  `exec` selects the non-interactive subcommand.

  `--json` switches the run onto the JSONL event stream the
  `:codex_jsonl` parser reads. Without it the CLI prints a human
  transcript in which the agent's own messages are indistinguishable
  from echoed prompts and command output, so the whole run — 122 KB
  of `rg` results in the case that prompted this — became the "plan".

  `--skip-git-repo-check` keeps a bootstrap run outside a checkout
  from aborting, and `--color never` keeps ANSI escapes out of
  `session.output_log`, which the task page renders verbatim.
  """
  @spec base_args() :: [String.t()]
  def base_args, do: @base_args

  @doc """
  Image carrying the Codex CLI (`runner-images/codex/Dockerfile`).

  A nil `runner_image` resolves to `alpine:latest` in the Swarm and
  DockerEngine backends, which has no `codex` binary at all, so this
  must be set for any containerised run.
  """
  @spec runner_image() :: String.t()
  def runner_image, do: "ghcr.io/t0ha/camelot-runner-codex:latest"

  @planning_system_prompt "You are in planning mode: investigate the " <>
                            "repository read-only and do not modify, " <>
                            "create, or delete any file. Your final message " <>
                            "must be the complete implementation plan in " <>
                            "Markdown and nothing else — no preamble, no " <>
                            "narration of what you are about to do, no " <>
                            "summary of what you read. It is captured as the " <>
                            "plan for approval exactly as you write it. If " <>
                            "you instead need input or a decision before the " <>
                            "plan can be finished, reply with nothing but " <>
                            "your questions, one per line, in under 400 " <>
                            "characters."

  @doc "Literal default system prompt for the planning run."
  @spec planning_system_prompt() :: String.t()
  def planning_system_prompt, do: @planning_system_prompt

  @doc "Slug of the `PromptTemplate` row holding the planning system prompt."
  @spec planning_system_prompt_slug() :: String.t()
  def planning_system_prompt_slug, do: "codex_planning_system_prompt"

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
  def execution_system_prompt_slug, do: "codex_execution_system_prompt"

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
  def pr_system_prompt_slug, do: "codex_pr_system_prompt"

  @doc """
  Per-stage sandbox/approval args for the `codex` template.

  Planning stays in the read-only sandbox so an investigation run
  cannot touch the workspace; executing and pr need to write files,
  run builds, and push, with no TTY available to approve at.
  """
  @spec permission_args_by_stage() :: %{optional(String.t()) => [String.t()]}
  def permission_args_by_stage do
    %{
      "planning" => ["--sandbox", "read-only"],
      "executing" => ["--dangerously-bypass-approvals-and-sandbox"],
      "pr" => ["--dangerously-bypass-approvals-and-sandbox"]
    }
  end

  @doc """
  Per-stage system prompts as `{{prompt:<slug>}}` placeholders,
  resolved at dispatch time by
  `Camelot.Runtime.AgentConfig.render_system_prompts/3` against the
  `PromptTemplate` rows named by the `*_system_prompt_slug/0`
  functions above, then prepended to the positional prompt.
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
  Phrases marking planning output as a clarifying question.

  Codex has no structured-output contract, so a question can only be
  recognised from the free text of the run — which is also why
  `planning_system_prompt/0` asks for a short, questions-only reply
  (`TaskRunner` only treats output under 500 characters as a
  question).
  """
  @spec question_phrases() :: [String.t()]
  def question_phrases, do: @question_phrases

  @doc """
  Output parser for this CLI: the `codex exec --json` event stream.

  See `Camelot.Runtime.OutputParser`. `:raw_text` — what the template
  originally carried — stored the entire human transcript as the run's
  result, so a planning run's "plan" was every command it ran and
  every line those commands printed.
  """
  @spec parser() :: :codex_jsonl
  def parser, do: :codex_jsonl
end
