# Runner provisioning progress

A task page used to look frozen for the first minutes of a run. The
session badge said `running`, the live-output panel was hidden, and
nothing else on the page moved — while behind the scenes Swarm was
scheduling a replica, a worker was pulling the runner image, or the
container entrypoint was cloning the repo and installing a toolchain.

None of that reaches `TaskRunner` as agent output, because the agent
CLI has not started yet. `ExecSession.start_exec/1` documents the
window deliberately: *"container scheduling, image pulls on workers,
and in-container clone+asdf install can each legitimately take
arbitrarily long"*. The wait is legitimate; the silence was not.

## The progress channel

`Camelot.Runtime.Progress.report/4` is the single funnel for
provisioning lines. Each call:

1. persists `progress_phase` / `progress_message` / `progress_at` on
   the session row, so a page loaded mid-flight (or a second viewer)
   sees the current line, and
2. broadcasts `{:runner_progress, task_id, %{session_id:, phase:,
   message:, at:}}` on the existing `task:<id>` PubSub topic, so open
   pages update live.

Persistence failures are logged and swallowed — a status line is never
worth failing a run over.

Phases, in the order a session normally passes through them:

| Phase | Reported by | Typical line |
|---|---|---|
| `:queued` | `TaskRunner.enqueue_session/4` | Queued — 2 session(s) ahead in the queue |
| `:provisioning` | `TaskRunner` slot grant, `ProvisionMonitor` | Starting the runner… / Scheduling the runner on a node… |
| `:pulling_image` | `ProvisionMonitor` | Pulling the runner image… |
| `:starting` | `ProvisionMonitor` | Starting the runner container… |
| `:workspace` | `ProvisionMonitor` | Setting up the workspace: asdf install (from .tool-versions) |
| `:running` | `ExecSession` | Agent started — waiting for its first output… |

The queue phases are backend-agnostic. `:pulling_image` is reported by
both backends — `ProvisionMonitor` for the Swarm one and
`DockerEngine.TaskContainer` when a local pull is needed. The
remaining lines come from the Swarm backend, which is where the long
waits actually happen.

## ProvisionMonitor

`Camelot.Runtime.Runner.Swarm.ProvisionMonitor` is a temporary
GenServer that `ExecSession` starts before its `with` chain and stops
in an `after` block, whichever way the hand-off ends. `ExecSession`
itself cannot report anything during that window — it is blocked in
`TaskService.get_service_id/1` (an `:infinity` call) and in the 500 ms
poll loops of `resolve_container/2` and `wait_for_ready/3`.

Every 3 seconds the monitor:

1. asks the manager for the tasks of `camelot-task-<task_id>` and maps
   the **newest** one's `Status.State` to a phase — historical
   shut-down replicas are ignored, the same trap
   `ExecSession.pick_running_task/1` guards against;
2. surfaces `Status.Err` when Swarm is stuck ("no suitable node
   (insufficient memory)" — a routine outcome on the small test nodes);
3. once a replica runs, tails that container's logs through the node
   proxy and reports the last `[entrypoint] …` line verbatim. The
   entrypoint already narrates `cloning <url> into /workspace` and
   `asdf install (from .tool-versions)`, which is exactly what the user
   wants to see during the longest phase.

Lines are reported only when they change, so a ten-minute image pull
emits one line, not two hundred.

## On the task page

`CamelotWeb.TaskLive` renders a **Runner status** row for any
`:running` session that has not produced output yet: a spinner, the
current line, and an elapsed counter ticking once a second (assigned
only while a session is provisioning, so an idle page produces no
diffs). The moment real output arrives the row gives way to the
existing **Live output** panel.
