# Usage-aware scheduling

Camelot can keep part of a provider's weekly quota free for your own,
manual use, run cards only in chosen time windows, and pin a card to a
start time or a best-effort deadline (GH#186). It all happens at
**dispatch time**: a held-back card simply stays `:queued`, and a
running session is never stopped.

The reactive path is unchanged and still applies on top: a run the
provider *rejects* as over its limit pauses the card and every sibling
on the same credential (`Camelot.Runtime.UsageLimit` →
`Camelot.Board.UsageLimitPause`).

## Settings

| Where | What | Stored as |
|---|---|---|
| Profile → Usage limits | Time zone | `User.time_zone` (IANA, default `Etc/UTC`) |
| Profile → Usage limits, per agent | Weekly cap %, run windows | `Camelot.Agents.UsagePolicy` (one row per user + agent) |
| Profile → Usage limits, per agent | Manual "current weekly usage %" | a `:manual` `Camelot.Agents.UsageSnapshot` |
| Task page → Schedule | Cap override, windows override, start at, finish by, "run even if over limits" | `Task.weekly_cap_override`, `windows_override`, `start_at`, `deadline_at`, `ignore_limits` |
| New Task form | Start at, finish by | `Task.start_at`, `deadline_at` |

No policy row means no restriction. On a card, `windows_override: nil`
inherits the policy's windows while `[]` lifts the restriction for that
card only. Pinning a card to a start or deadline sets `ignore_limits`
unless the request says otherwise (`Task.Changes.ImplyIgnoreLimits`).

## Time zones

Everything in the database is UTC. `User.time_zone` is only used by the
UI, through `Camelot.TimeZone`:

* `datetime-local` inputs are read in the user's zone and stored in UTC;
* run windows are stored as **UTC minutes of the week**
  (`Camelot.Agents.RunWindow`: `0` = Monday 00:00 UTC, `10079` = Sunday
  23:59 UTC; `end_minute < start_minute` wraps past Sunday) and edited as
  local weekday rows.

Windows are converted at the zone's offset at save time, so across a
DST change a weekly window shifts by an hour in local time; the profile
re-renders it at the current offset and the user can re-save. One-off
`start_at`/`deadline_at` are converted exactly.

## Where the usage number comes from

A `UsageSnapshot` belongs to the **credential** the reading describes,
because both CLIs report the account's quota rather than the agent's —
two agents on one key see the same numbers. A key supplied by env var
has no `Credential` row; its snapshots fall back to user + credential
kind. The latest unexpired row is authoritative; a row whose
`resets_at` has passed is ignored.

| Source | How |
|---|---|
| `:cli` (Claude Code) | `Camelot.Runtime.TaskRunner.finish_session/5` parses the **last** `rate_limit_event` of every run (success or failure) with `Camelot.Runtime.RateLimitEvents`: `rate_limit_info.unifiedWindows.seven_day` → `:weekly`, `five_hour` → `:session`, `utilization` × 100, `resetsAt` epoch seconds. Older CLIs that send only the top-level `rateLimitType`/`resetsAt` record nothing. |
| `:manual` | Typed on the profile. Keeps the provider's last known reset, or assumes a fresh week. |
| `:estimated` | Computed, never stored: a manual reading plus Camelot's own session time on that account since the reading (`duration_ms` of the user's finished sessions whose agent mounts the same credential kind), at `config :camelot, :scheduling, minutes_per_percent`. It cannot see use outside Camelot. |

Codex keeps its limit data in its rollout file
(`$CODEX_HOME/sessions/…/rollout-*-<thread_id>.jsonl`, `token_count`
events with `payload.rate_limits`), not on stdout, so Codex uses manual
entry plus the estimate for now. Reading the rollout file is a
follow-up.

## The gate

`Camelot.Scheduling.Gate.decide/5` is pure; first match wins:

1. `start_at` in the future → wait until `start_at`.
2. Deadline within two estimated runs → run ahead of the queue,
   ignoring cap and windows: `:promoted`, or `:at_risk` once even an
   immediate start is estimated to finish late.
3. `ignore_limits` → run; flagged `:reserve_risk` when already over the
   cap.
4. Weekly cap (card override, else policy) reached → wait until the
   snapshot's `resets_at`. No snapshot or no cap passes.
5. Outside every run window → wait until the next one opens. No
   windows passes.
6. Otherwise run.

The estimate is the p80 of the last 50 completed sessions for the same
agent and stage (`Session.stage`), falling back to
`duration_fallback_minutes` (`Camelot.Scheduling.DurationEstimate`).

`Camelot.Scheduling.Planner` loads every input for a batch of cards in a
few queries and orders what may run: promoted/at-risk cards first, then
nearest `deadline_at` (none last), then priority.
`Camelot.Board.Changes.DispatchTasks.apply_gate/2` uses it on every
tick; the `Task.scheduled_wait` calculation uses the same call for the
board and task-page badges, so the two cannot disagree.

## Configuration

```elixir
config :camelot, :scheduling,
  minutes_per_percent: 30,       # run minutes counted as 1% of a manual reading
  duration_fallback_minutes: 30  # run estimate before any history exists
```

## Telemetry

`task_gated` (when a card's gate reason changes) and
`usage_snapshot_recorded` — see `docs/telemetry.md`.
