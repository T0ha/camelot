# Codex agent CLI

How the built-in `codex` agent template is wired, and why it differs from
`claude_code`. Source of truth: `Camelot.Agents.CodexDefaults`.

## What was broken

The row seeded by `20260527063144_add_agent_templates.exs` was written
against a Codex CLI that no longer exists. It carried
`base_args = ["--quiet"]`; the modern CLI (0.4x+) has no such flag and
puts non-interactive runs behind an `exec` subcommand, so every dispatch
died before any model call:

```
error: unexpected argument '--quiet' found
Usage: codex [OPTIONS] [PROMPT]
```

Exit code 2, no output to parse, so the session surfaced only
*"The runner exited with a non-zero status without reporting a reason."*
The run then retried `max_retries` times and errored the task.

Three further gaps would each have broken a run that got past that:

| Gap | Effect |
|---|---|
| `runner_image` nil | Swarm/DockerEngine fall back to `alpine:latest`, which has no `codex` binary |
| `required_credential_kinds` empty | No `OPENAI_API_KEY` mounted (`:codex_api_key` maps to it in `Runner.SecretEnv`) |
| No per-stage system prompt | Nothing told the agent to emit a plan, or to finish by opening a PR |

`20260922060000_fix_codex_for_modern_cli.exs` repairs all of it, guarded
on `base_args` still being exactly `["--quiet"]` so a hand-edited row at
`/agents` is left alone.

## Argv shape

`base_args` is `exec --skip-git-repo-check --color never`:

- **`exec`** — the non-interactive subcommand. Without it argv is parsed
  as options to the interactive TUI.
- **`--skip-git-repo-check`** — keeps a run outside a checkout (e.g. a
  bootstrap session) from aborting.
- **`--color never`** — the `:raw_text` parser stores stdout verbatim in
  `session.output_log` and the task page renders it; ANSI escapes would
  survive into both.

`prompt_flag` is nil, so the prompt is positional — `codex exec [PROMPT]`.

## Sandbox posture

Codex has no TTY to approve at in a headless run, so each stage states
its posture explicitly in `permission_args_by_stage`:

| Stage | Args |
|---|---|
| `planning` | `--sandbox read-only` |
| `executing` | `--dangerously-bypass-approvals-and-sandbox` |
| `pr` | `--dangerously-bypass-approvals-and-sandbox` |

The bypass is the documented posture for an *externally sandboxed*
environment, which is what the Swarm and DockerEngine backends give it:
a throwaway container holding one task's clone.

> **`LocalPort` caveat.** Under the local-port backend the agent runs
> directly on the developer's machine against their own checkout, where
> that flag means no sandbox at all. Tighten it per project
> (`permission_args_by_stage_override`) or per agent (`/agents`) before
> running this template locally.

## System prompts

Claude Code takes its stage system prompt as a flag
(`--append-system-prompt`, carried inside `permission_args_by_stage`).
Codex has no equivalent, so the `agents.system_prompt_by_stage` column
holds it instead and `AgentConfig.build_cli_args/5` prepends the resolved
text to the positional prompt, separated by a blank line.

Values are `{{prompt:<slug>}}` placeholders resolved at dispatch time by
`AgentConfig.render_system_prompts/3`, against `PromptTemplate` rows with
the usual project → user → system-global precedence — so the text is
editable at `/prompts` and overridable per project, exactly like the
Claude ones. A missing row falls back to the literal in `CodexDefaults`
rather than blanking the prompt.

A CLI uses one channel or the other, never both: a row carrying the same
text in `permission_args_by_stage` *and* `system_prompt_by_stage` would
send it twice.

## Planning output

There is no structured-output contract here — `parser` is `:raw_text`, so
`TaskRunner.planning_action/2` falls through to the free-text path and
the whole run output becomes the plan. Two consequences shape
`planning_system_prompt/0`:

- the final message must *be* the plan, since it is captured verbatim;
- a clarifying question is only recognised from free text, and only when
  the output is under 500 characters and matches `question_phrases` —
  hence the instruction to reply with nothing but the questions.

See [planning-output-contract.md](planning-output-contract.md) for how
Claude Code does this instead.

## Models

`available_models` and `default_model` are deliberately empty: the CLI's
current `--model` values aren't pinned here. Fill them in at `/agents`
once verified against the CLI's own docs; until then Codex uses its own
default.
