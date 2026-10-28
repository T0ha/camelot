defmodule Camelot.Agents.KimiDefaults do
  @moduledoc """
  Canonical CLI defaults for the built-in `kimi` agent template,
  written against Kimi Code CLI 2.3.0 (`@moonshot-ai/kimi-code`).

  Single source of truth shared by `priv/repo/seeds.exs`, the data
  migration that seeds already-installed databases, and the
  regression tests — the role `Camelot.Agents.CodexDefaults` plays for
  `codex`.

  Three things shape everything below:

    * Headless runs are `kimi -p "<prompt>" --output-format
      stream-json`, and print mode is already auto-permission: the
      agent writes files and runs `Bash` with no extra flag, and does
      not hang on `AskUserQuestion`.

    * `--plan` cannot be combined with `-p` (the CLI exits 1), so the
      read-only planning posture comes from an agent file that
      allowlists only the read tools — see
      `permission_args_by_stage/0`.

    * There is no `--append-system-prompt` and no schema flag, so the
      per-stage system prompt is prepended to the prompt by
      `Camelot.Runtime.AgentConfig` (as for Codex), and the planning
      decision contract is spelled out in that prompt as text.

  Kimi has no `setup-token` equivalent: `kimi login` keeps its OAuth
  tokens inside `~/.kimi-code`. One `:kimi_api_key` credential takes
  either a Kimi Code Console key or a Kimi Open Platform key, and the
  runner entrypoint probes which endpoint it belongs to (see
  `runner-images/base/entrypoint.sh`, `kimi_configure`).
  """

  @doc "CLI binary name."
  @spec executable() :: String.t()
  def executable, do: "kimi"

  @doc "Flag carrying the prompt; it also selects print (headless) mode."
  @spec prompt_flag() :: String.t()
  def prompt_flag, do: "-p"

  @doc "Flag selecting the model alias."
  @spec model_flag() :: String.t()
  def model_flag, do: "-m"

  @doc """
  Static args prepended to every run.

  `--output-format stream-json` switches the run onto the JSONL event
  stream the `:kimi_jsonl` parser reads.
  """
  @spec base_args() :: [String.t()]
  def base_args, do: ["--output-format", "stream-json"]

  @doc """
  Env every run gets, via `Agent.env_vars` and
  `Camelot.Runtime.AgentConfig.env_for_port/1`.

  Trusts the cloned workspace without a prompt, and keeps the CLI from
  updating itself or phoning home from a throwaway runner.
  """
  @spec env_vars() :: %{String.t() => String.t()}
  def env_vars do
    %{
      "KIMI_CODE_TRUST_WORKSPACE" => "1",
      "KIMI_CODE_NO_AUTO_UPDATE" => "1",
      "KIMI_DISABLE_TELEMETRY" => "1"
    }
  end

  @available_models [
    "kimi-code/k3",
    "kimi-code/k3.1-pro",
    "kimi-code/k3.1-pro-highspeed",
    "kimi-code/k3-256k",
    "kimi-code/kimi-for-coding",
    "kimi-code/kimi-for-coding-highspeed"
  ]

  @doc """
  Model aliases the `-m` flag accepts — the offline fallback for
  `Camelot.Agents.ModelDiscovery`.

  Every value is `kimi-code/<id>`: the alias form `kimi login` writes
  into a developer's own `~/.kimi-code/config.toml`, and the one the
  runner entrypoint writes for every id the key may use. The same
  `-m kimi-code/k3` therefore works on `LocalPort` and in containers.
  A model the config doesn't know fails fast with
  `Model "kimi-code/x" is not configured in config.toml`.

  `default_model` is left nil, like Codex: the config's own
  `default_model` (chosen from the live listing in a container, or the
  developer's own default on `LocalPort`) applies.
  """
  @spec available_models() :: [String.t()]
  def available_models, do: @available_models

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

  @doc """
  Probe config for live, per-user model discovery — see
  `Camelot.Agents.ModelDiscovery`.

  A Kimi key belongs to one of four OpenAI-style endpoints (Code
  Console or Open Platform, global or China), so the probe walks
  `"candidates"` in order and the first that answers wins — the same
  order the runner entrypoint probes in. `include` drops the Open
  Platform catalog's non-coding models; `id_prefix` turns each id into
  the `kimi-code/<id>` alias `-m` takes.
  """
  @spec models_probe() :: map()
  def models_probe, do: @models_probe

  @doc """
  Credential kinds that satisfy this CLI's auth.

  `:kimi_api_key`, which `Camelot.Runtime.Runner.SecretEnv` mounts as
  `CAMELOT_SECRET_KIMI_API_KEY` for the entrypoint to turn into a
  `config.toml`.
  """
  @spec required_credential_kinds() :: [atom()]
  def required_credential_kinds, do: [:kimi_api_key]

  @doc """
  Image carrying the Kimi Code CLI (`runner-images/kimi/Dockerfile`).
  """
  @spec runner_image() :: String.t()
  def runner_image, do: "ghcr.io/t0ha/camelot-runner-kimi:latest"

  @doc """
  Read-only agent file baked into the kimi runner image.

  Its `tools` allowlist is `Read`, `Glob`, `Grep` — no `Bash`, so a
  planning run cannot run `git log` or tests, unlike Codex's read-only
  sandbox.
  """
  @spec planning_agent_file() :: String.t()
  def planning_agent_file, do: "/opt/agent-cli/kimi/planning-agent.md"

  @planning_system_prompt "You are in planning mode: investigate the " <>
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

  @doc "Literal default system prompt for the planning run."
  @spec planning_system_prompt() :: String.t()
  def planning_system_prompt, do: @planning_system_prompt

  @doc "Slug of the `PromptTemplate` row holding the planning system prompt."
  @spec planning_system_prompt_slug() :: String.t()
  def planning_system_prompt_slug, do: "kimi_planning_system_prompt"

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
  def execution_system_prompt_slug, do: "kimi_execution_system_prompt"

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
  def pr_system_prompt_slug, do: "kimi_pr_system_prompt"

  @doc """
  Per-stage args for the `kimi` template.

  Planning loads the read-only agent file (`planning_agent_file/0`),
  which leaves the model exactly `Read`, `Glob` and `Grep`; executing
  and pr need nothing, print mode being auto-permission already.
  """
  @spec permission_args_by_stage() :: %{optional(String.t()) => [String.t()]}
  def permission_args_by_stage do
    %{
      "planning" => ["--agent-file", planning_agent_file()],
      "executing" => [],
      "pr" => []
    }
  end

  @doc """
  Per-stage JSON Schema — none: Kimi has no schema flag. Explicitly
  empty so `Camelot.Runtime.AgentConfig` writes no schema file nobody
  reads.
  """
  @spec output_schema_by_stage() :: %{optional(String.t()) => String.t()}
  def output_schema_by_stage, do: %{}

  @doc """
  Per-stage system prompts as `{{prompt:<slug>}}` placeholders,
  resolved by `Camelot.Runtime.AgentConfig.render_system_prompts/3`
  and prepended to the prompt.
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
  fallback for a planning answer that didn't decode to the JSON
  decision object.
  """
  @spec question_phrases() :: [String.t()]
  def question_phrases, do: @question_phrases

  @doc """
  Output parser for this CLI: the `--output-format stream-json`
  event stream. See `Camelot.Runtime.OutputParser`.
  """
  @spec parser() :: :kimi_jsonl
  def parser, do: :kimi_jsonl
end
