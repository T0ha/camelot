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
| `required_credential_kinds` empty | No `OPENAI_API_KEY` mounted (`:openai_api_key` maps to it in `Runner.SecretEnv`) |
| No per-stage system prompt | Nothing told the agent to emit a plan, or to finish by opening a PR |
| `parser: :raw_text` | The whole human transcript became the run's result — see [Output parsing](#output-parsing) |

`20260922060000_fix_codex_for_modern_cli.exs` repairs all of it, guarded
on `base_args` still being exactly `["--quiet"]` so a hand-edited row at
`/agents` is left alone.

## Argv shape

`base_args` is `exec --json --skip-git-repo-check --color never`:

- **`exec`** — the non-interactive subcommand. Without it argv is parsed
  as options to the interactive TUI.
- **`--json`** — the JSONL event stream the `:codex_jsonl` parser reads.
  See [Output parsing](#output-parsing) below. Planning additionally
  passes `--output-schema`; see [Planning output](#planning-output).
- **`--skip-git-repo-check`** — keeps a run outside a checkout (e.g. a
  bootstrap session) from aborting.
- **`--color never`** — `session.output_log` stores stdout verbatim and
  the task page renders it; ANSI escapes would survive into both.

`prompt_flag` is nil, so the prompt is positional — `codex exec [PROMPT]`.

## Output parsing

The template originally carried `parser: :raw_text`, which stores the
whole run as its result. The first successful planning run therefore
produced a **122 KB "plan"**: the echoed prompt, every `rg`/`sed` the
agent ran, and every line those printed — with the actual plan as the
last few hundred lines.

`--json` makes the CLI emit one event per line instead:

```jsonc
{"type":"thread.started","thread_id":"01a0…"}
{"type":"turn.started"}
{"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":"…"}}
{"type":"item.completed","item":{"id":"item_1","type":"command_execution","command":"…","aggregated_output":"…","exit_code":0,"status":"completed"}}
{"type":"turn.completed","usage":{"input_tokens":25809,"output_tokens":137,…}}
```

`OutputParser.parse(:codex_jsonl, buffer)` keeps only `agent_message`
items — `reasoning`, `command_execution`, `file_change`, `mcp_tool_call`,
`web_search` and `todo_list` are the working noise — and reads token
counts off `turn.completed`. A `turn.failed` event becomes an error even
though the process still exits 0. Undecodable lines are dropped, so the
entrypoint's log lines and the CLI's own stderr notes ("Reading
additional input from stdin…") pass through harmlessly.

One visible trade-off: `session.output_log` now holds JSONL rather than
the human transcript, so the task page's live-output panel shows events
instead of prose. That is already how `claude_code` behaves — it runs
`--output-format stream-json` — and the panel renders whatever the CLI
wrote, verbatim. There is no second stream to keep the prose in.

**Only the last `agent_message` is the answer.** Codex emits its
progress narration ("I'll trace the config path first…") as its own
`agent_message` items *ahead* of the answer, so unlike Claude Code —
where `assistant_texts` collects every turn because the plan may sit in
one before the final result field — joining them here would prefix every
plan with throat-clearing, and would push a clarifying question past the
500-character ceiling `TaskRunner.planning_action/2` uses to recognise
one. The full transcript remains in `session.output_log` either way.

## Sandbox posture

Codex has no TTY to approve at in a headless run, so each stage states
its posture explicitly in `permission_args_by_stage`:

| Stage | Args |
|---|---|
| `planning` | `--sandbox read-only`, `--output-schema <path>` |
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

Planning runs under `--output-schema`, the analogue of the
`--json-schema` contract `claude_code` has had since
[planning-output-contract.md](planning-output-contract.md). The final
message is then a validated object rather than prose:

```json
{"decision": "plan", "plan": "## Implementation plan\n\n1. …", "questions": null}
```

`OutputParser` surfaces it as `structured`, and
`TaskRunner.planning_action/2` reads the decision directly through the
same path Claude Code's structured output takes — no guessing whether
prose is a plan or a question. `question_phrases` survives only as the
fallback for a run whose structured decision is missing.

### Strict mode

Codex forwards the schema to OpenAI's **strict** structured-output mode,
which is narrower than the schema `claude_code` uses. Two rules:

- `additionalProperties` must be present and `false`;
- **every** property must be listed in `required` — an optional field is
  expressed as a nullable union (`["string", "null"]`) instead.

Break either and the turn fails with a 400 *before the model runs*:

```
invalid_request_error / invalid_json_schema:
  'additionalProperties' is required to be supplied and to be false.
```

That arrives as a `turn.failed` event on a process that still exits 0,
which is why the parser treats `turn.failed` as an error.

### How the file gets there

`--output-schema` takes a **file**, and the argv naming it is built
before the backend is chosen, so every backend materialises it at the
same session-scoped path (`Runner.Spec.output_schema_path/1`):

| Backend | Who writes it |
|---|---|
| Swarm, DockerEngine | `exec-wrapper.sh`, from `CAMELOT_OUTPUT_SCHEMA_JSON` passed at exec time |
| LocalPort | the `LocalPort` GenServer itself, before opening the port |

The schema body lives on the agent row (`output_schema_by_stage`), and
`{{output_schema_path}}` in that stage's `permission_args_by_stage`
resolves to the path — so both halves stay editable at `/agents`.

> **Deploy note.** The wrapper change ships in the runner image, so a
> containerised install needs `runner-images` rebuilt and re-pulled
> before planning runs can find the schema file.

## Credentials

`required_credential_kinds` is `[:openai_api_key]`, mounted as
`OPENAI_API_KEY`. There is no ChatGPT-account path: a runner container
has no browser login, so an API key is the only option.

### The env var alone is not enough

**Codex reads its credentials from `$CODEX_HOME/auth.json`, never from
`OPENAI_API_KEY`.** With the key only in the environment, every request
goes out unauthenticated:

```
401 Unauthorized: Missing bearer or basic authentication in header
```

which reads as a bad key rather than an unused one. The tell is
`Missing bearer` — a key that *was* sent and rejected reports
`auth error code: invalid_api_key` instead.

So the runner image authenticates the CLI wherever the key lands:

| Script | Why |
|---|---|
| `entrypoint.sh` → `codex_login` | container boot / bootstrap runs |
| `exec-wrapper.sh` | task sessions arrive as `docker exec` with the key in the **exec-time** environment, which the entrypoint never saw |

Both pipe the key into `codex login --with-api-key`, which takes it on
stdin so it never lands in argv or `ps`, and both no-op in images
without the CLI. There is no config-file equivalent —
`preferred_auth_method`, `auth_mode` and `use_api_key` are all rejected
by `--strict-config` — so this cannot be solved from `base_args`.

> **Deploy note.** This lives in the runner image, so a containerised
> install needs `runner-images` rebuilt and re-pulled before Codex can
> authenticate at all.

A second kind, `codex_api_key`, used to exist alongside it. Both mounted
the same variable and nothing ever branched on the difference, so the
choice between them was cosmetic — except that this row required only
`codex_api_key`, and a user who stored their key under the obvious
`openai_api_key` got no key mounted at all and four runs that failed
with `401 Unauthorized: Missing bearer or basic authentication`, which
reads as a bad key rather than a missing one. The kind was retired in
`20260925110000_retire_codex_api_key_credential_kind.exs`, which
converts any stored row.

Credential kinds name the **provider**, not the agent CLI that reads
them — `claude_api_key`, not `claude_code_api_key`. A future
ChatGPT-token path would discriminate on the value inside one kind,
exactly as `claude_api_key` already does for `sk-ant-oat*`.

## Models

`available_models` is `gpt-5.6-terra`, `gpt-5.6-luna`, `gpt-5.5`. The CLI
has no "list models" command, so that list was established by invoking
each candidate against codex-cli 0.155.0 and keeping the ones whose turn
completed. The rejects — `gpt-5.6-sol`, `gpt-5.4`, `gpt-5.3-codex`,
`gpt-5.2`, `gpt-5.1-codex-max` — return:

```
400 invalid_request_error:
  The 'gpt-5.4' model is not supported when using Codex with a ChatGPT account.
```

after a `Model metadata … not found` warning that, on its own, reads as
survivable and isn't.

**That set is scoped to the account the probe ran under**, not a property
of the CLI: another plan, or API-key auth, may accept a different list.
Treat it as a sensible default and edit it at `/agents` when it doesn't
match. Discovering it per install is
[issue #165](https://github.com/T0ha/camelot/issues/165).

`default_model` is deliberately nil. With no `--model` the CLI picks its
own default (`gpt-5.6-terra` today), which degrades gracefully on an
install that isn't entitled to whichever id we'd otherwise have pinned.
