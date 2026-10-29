# Recurring tasks

A card can repeat — daily, weekly on chosen weekdays, or monthly on a
day of the month, at a local time, every N days / weeks / months. Each
run is a **new card**, editable until it starts.

## Setting it up

Open a card, then **Schedule → Repeat**:

| Field | Meaning |
|---|---|
| Repeat | Don't repeat / Daily / Weekly / Monthly |
| Every N | Interval, counted from the day the repeat was created |
| At | Local time in your profile's time zone (`User.time_zone`) |
| On (weekly) | Weekdays to run on — at least one |
| Day of month (monthly) | 1–31; a later day than a month has runs on its last day |
| Repeat until | Optional: no run is created for a later occurrence |
| Skip planning on each run | Each new card starts straight in execution, its description taken as the plan |

Saving on a one-off card creates a `Camelot.Board.RecurrenceRule` and
makes the card the first of the series. If the card has not started yet
it is pinned (`start_at`) to the first occurrence and waits on the board
with the usual "Starts …" badge; a card that already ran keeps its own
schedule. Saving again updates the rule — and re-pins an upcoming card
that has not started. **Don't repeat** turns the series off
(`:disable`): the rule and its cards are kept, the current card stays as
a one-off. The Repeat block is shown on finished cards too, so a done
task can be made recurring.

Recurring cards carry a repeat icon on the board.

## How runs are created

A series has at most **one open card**. When it reaches `:done` or
`:cancelled`, the `:spawn_next` AshOban trigger (every minute) creates
the next card for the first occurrence after **now** — and after the
finished card's own slot, so cancelling an upcoming run skips it rather
than recreating it.

- **No overlap.** While a card is open — queued, running, or waiting in
  PR review — no new card is created; the slots that pass meanwhile are
  skipped.
- **No backlog.** After downtime, or a run that took days, you get one
  card for the next slot, never one per missed slot.
- **Edits carry forward.** The next card copies the **latest** card of
  the series: title, description, priority, model, cap and window
  overrides, "run even if over limits", project, agent and creator,
  and a deadline at the same offset from the start. Editing the
  upcoming card therefore changes every run after it.

The card is an ordinary `Task` `:create` with `start_at` and
`recurrence_rule_id` set, so `Camelot.Scheduling.Gate` holds it until
its start, and model validation, notifications and telemetry apply as
for any card. The series turns itself off when it cannot go on: the
next occurrence is past "repeat until", no card is left to copy, the
agent was deleted, or the next card would be invalid (e.g. a model the
agent no longer offers). The trigger skips rules in archived projects.

## Editing until started

The task page shows **Edit** (title, description, priority) while a
card is `:queued` and has never had a session. The primary `Task`
`:update` enforces the same rule (`Task.Validations.NotStarted`), so an
agent never runs against a description that changed under it.

## Time zones and DST

Occurrences are local wall-clock times in the zone saved on the rule
(your time zone at the time you saved it), computed by
`Camelot.Scheduling.Recurrence`. "Daily at 09:00" stays at 09:00 local
across DST changes — unlike run windows, which are fixed in UTC. A time
inside the spring-forward gap runs right after the gap; one inside the
fall-back overlap runs at its first occurrence. Everything is stored in
UTC (`next_run_at`, `Task.start_at`).

## Telemetry

`recurrence_created`, `recurrence_updated`, `recurrence_disabled` and
`recurrence_spawned` — see `docs/telemetry.md`. A `recurrence_spawned`
with `enabled: false` is a series that stopped itself instead of
creating a card.
