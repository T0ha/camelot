# Planning output contract

How Camelot captures a **plan** or a **clarifying question** from a
headless Claude Code planning run.

## Why a contract is needed

The runner's Claude Code is a ToolSearch/deferred-tools build. In headless
mode (`-p --output-format stream-json --permission-mode plan`) the
`system/init` event's tool registry does **not** contain `ExitPlanMode`
or `EnterPlanMode`. The original design — "the agent calls `ExitPlanMode`,
headless denies it, and we recover the plan from the denial's
`tool_input.plan`" — therefore never fires. Worse, the final
`type:"result"` event's `result` field is only the agent's **last
assistant turn** (often a throwaway sentence such as *"I'll wait for your
decision…"*), so a plan or question raised in an earlier turn is lost.

The symptom: a task sits in `planning / waiting_for_input` with a
meaningless `plan` and **no `TaskMessage`**, so the UI shows a plan-approval
card with nothing useful and no question.

## The contract

Planning runs pass `--json-schema` (see `priv/repo/seeds.exs`,
`claude_code` template, `permission_args_by_stage["planning"]`). This
injects a `StructuredOutput` tool that **coexists with the normal
read-only investigation tools** (Bash, Read, Edit, WebFetch, Task,
ToolSearch, …). The agent explores the repo, then delivers its result by
calling `StructuredOutput` with:

```json
{
  "decision": "plan" | "question",
  "plan": "…full Markdown plan…",        // when decision = "plan"
  "questions": ["…", "…"]                 // when decision = "question"
}
```

An `--append-system-prompt` reinforces the rule: *never ask questions as
plain assistant text; always use `StructuredOutput`.*

## How it is parsed

For a `--json-schema` run, the final `type:"result"` event carries the
validated object under **`structured_output`** (and the same payload as a
JSON string under `result`). `Camelot.Runtime.OutputParser` surfaces it as
`parsed.structured`, and also exposes `parsed.assistant_texts` — every
top-level assistant turn — as a fallback source of truth.

`Camelot.Runtime.AgentProcess.planning_action/2` routes, in precedence:

1. `structured.decision == "plan"` → `submit_plan/3` with the full plan.
2. `structured.decision == "question"` → `request_user_input/3`, which
   always writes a `TaskMessage` so the UI can show the question.
3. Legacy `ExitPlanMode` denial (kept as a fallback).
4. Tool-permission denials → request input.
5. A free-text question detected across the **full** transcript.
6. Empty output → task error.
7. Otherwise → treat the full transcript as the plan.

## Invariants

- A question path always persists a `TaskMessage` with the real text.
- A plan path always stores the full plan, never a trailing sentence.
- The agent's response is always recorded in the conversation. When an
  executing run ends without a PR (e.g. a checks-only task with nothing
  to submit), the task still transitions to `error`, but the agent's
  final response is persisted as an assistant `TaskMessage` first — so
  the conversation explains why, rather than showing a bare error.

## Scope

Only the `planning` stage uses `--json-schema`. The `executing` and `pr`
stages produce free text (a PR URL) and must not be forced into structured
output; they still detect `AskUserQuestion` denials to route questions.
