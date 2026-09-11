# Session adoption (reconnect after restart)

When 🏰 Camelot AI is redeployed, Swarm/Docker sends the app SIGTERM and the
`TaskRunner` GenServers driving in-flight runs die. The **runner
containers are separate services that keep running** (the agent process
inside them is a `docker exec`, not tied to the app's connection), so the
work isn't actually lost — only the app's live view of it.

Previously the Reconciler marked every such `:running` session **failed**
on boot, discarding in-flight work and leaving the task stuck
`in_progress` with an orphaned runner. Adoption reconnects instead.

## How it works

1. **Durable output + completion marker.** The in-container
   `exec-wrapper.sh` already tees the agent's full output to
   `/tmp/camelot-output-<session_id>.log`. It now also writes the exit
   code to `/tmp/camelot-exit-<session_id>` **after** the tee — so the
   marker's presence implies the output file is complete. The marker is
   needed because the original `docker exec` id is lost across a restart,
   so the app can't poll the exec for its status.

2. **Reconciler decides adopt vs. fail** (`recovery_action/4`, pure):
   for a `:running` session whose owning `TaskRunner` is gone, if it's
   a **task** session (not bootstrap), on a container backend (not
   LocalPort), with a runner handle whose container probe is `:present`
   → **adopt**. Otherwise → **fail** (retryable).

3. **TaskRunner adopts** (`TaskRunner.adopt/2`, `adopt(task_id,
   session_id)`): rebuilds the minimal state finalisation needs (config,
   task, output-so-far) and starts the runner in **adopt mode**
   (`Spec.adopt? = true`) — bypassing the `RunnerPool` (no new slot) and
   creating **no new exec**. The session is flagged `was_adopted`.

4. **Adopt-mode runner** (`ExecSession`, both backends): resolves the
   existing container and polls for the completion marker
   (`AdoptMarker`). When it appears, it reuses the normal `{:exit_code,
   _}` path — fetch the tee'd output, emit `{:runner_output, …}` then
   `{:runner_exit, code}` — so the run finalises exactly as a live one
   would (plan/PR/question routing all unchanged).

## When adoption can't work: interruption

Adoption only helps when the container the exec ran in is still the one
that's up. Two things routinely make that false:

- the boot sweep re-pins a floating runner-image tag to a newly published
  digest, and Swarm **replaces the container**;
- Swarm reschedules the replica (node partition, OOM).

Either way `/tmp` — and with it the tee'd output and the completion
marker — is gone, so the run can never report a result. That is an
**interruption**, not a failure of the task, and it is handled as such:

1. `Camelot.Runtime.Runner.AdoptPolicy` bounds the adoption poll, giving
   up on `:container_replaced` (re-checked on *every* iteration, since a
   roll can land mid-adoption) or `:timeout`.
2. The backend reports `{:runner_interrupted, pid, reason}` — a distinct
   message from `{:runner_exit, pid, code}`, so `TaskRunner` never parses
   the stale reloaded buffer as if it were this run's result.
3. `Camelot.Board.Interruption` puts the task back to `state: :queued`
   and the every-minute `dispatch_tasks` cron simply runs it again from
   its current stage. No error card, no error email.
4. Only a task that keeps being interrupted without ever completing a run
   exhausts `interrupt_requeues` (cap:
   `:camelot, :runner, :max_interrupt_requeues`, default 3) and lands in
   `state: :error` with the last interruption as its `last_error`.

The boot sweep re-pins images **before** the reconcile pass, so a rolled
container's sessions are failed and re-queued up front rather than being
handed to an adoption that would poll for a container that no longer
exists. Services are also digest-pinned at *create* time, so a redeploy
that ships no new runner image rolls nothing at all.

## Caveats

- **Requires the runner image rebuilt** with the marker-writing
  `exec-wrapper.sh`. A session started under an older image never
  produces a marker; adopt it only once images are updated, otherwise
  retry the task.
- **Live incremental output** streamed *before* the restart is not
  replayed, but the final result is complete (read whole-file). This is
  what the `Session.was_adopted` UI hint flags.
- If the container is genuinely gone (node lost, service removed), there
  is nothing to adopt → the session is failed and the task-runner-lost
  sweep re-queues the task with a fresh runner.
- LocalPort (single-node/dev/test) has no container to re-attach to;
  adoption is a no-op there.

## Not covered here

Graceful drain on SIGTERM (checkpoint/finish in-flight runs before exit)
and the app-image multi-arch / placement issue are tracked separately.
