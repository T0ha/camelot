# Task links

Tasks can declare three kinds of link to another task, including one in a
different project (`Camelot.Board.TaskLink`, `lib/camelot/board/task_link.ex`):

| Link | Meaning | Gates dispatch? |
|---|---|---|
| `:blocks` | source must reach stage `:pr` (or terminate at `:done`/`:cancelled`) before the target may dispatch | yes |
| `:parent_of` | source is the umbrella task, target is a subtask | yes — the parent waits on every subtask |
| `:relates_to` | informational cross-reference (symmetric) | no |

A task can have at most one parent. `:relates_to` is stored with the smaller
task id as `source_task_id` so the same fact can't be inserted as two rows
(`A relates_to B` and `B relates_to A`).

## Gating

`Camelot.Board.Task.blocked?` is a calculation over two aggregates
(`blocked_by_blockers?`, `blocked_by_subtasks?`) recomputed on every read —
nothing is stamped, so a blocker reaching `:pr` frees its dependents on the
very next `dispatch_tasks` tick with no extra bookkeeping.
`Camelot.Board.Changes.DispatchTasks` filters on `not blocked?` directly in
the query; `Task.begin_work` re-checks it in a `before_action` hook so a
manual Retry/Reset can't jump the gate.

A blocker only needs to reach stage `:pr`, not `:done` — waiting for a merge
would serialize everything behind human review, and a pushed branch is
enough for the dependent to build on.

## Stacked branches

For a same-repo `:blocks` blocker at stage `:pr`,
`Camelot.Board.PromptBuilder.branch_directive/1` tells the dependent to
branch off the blocker's `camelot/task-<id>` branch and open its PR against
it instead of the default branch:

```
main
 └── camelot/task-A          blocker,   PR #1 → main
      └── camelot/task-B     dependent, PR #2 → camelot/task-A
```

Two or more same-repo blockers at `:pr` fall back to branching from the
default branch and merging each blocker branch in first. Cross-repo
blockers never get a branch directive — there is no git relationship to
express — but they still gate dispatch and still show up in the prompt's
"Related Tasks" context block (`PromptBuilder.related_context_block/1`).

## Branch sync

`Camelot.Board.Changes.CheckPrStatus.propagate_to_dependents/2` reuses the
existing `check_pr_status` poll (every 2 minutes, `stage == :pr` tasks) to
notice when a blocker's branch moves and tell its same-repo dependents to
rebase, via a `TaskMessage`. A dependent that hasn't branched yet just has
its synced sha recorded; a `:waiting_for_input`/`:error` dependent is also
re-queued (`action: :reset`). When the blocker's PR merges, dependents are
told to rebase onto the default branch and retarget their PR instead.

## UI

- `CamelotWeb.Components.TaskPicker` — a debounced search LiveComponent used
  both by `BoardLive`'s create-task modal (optional "Parent task" / "Blocked
  by" pickers) and `TaskLive`'s "Add link" modal.
- `TaskLive` renders a "Linked Tasks" card (Parent / Blocked by / Blocks /
  Subtasks / Related) and a blocked banner. Board resources have no Ash
  policies, so `TaskLive` filters loaded link lists through
  `CamelotWeb.Scope.scope_tasks/2` itself and collapses anything the current
  user can't see into a single placeholder count.
