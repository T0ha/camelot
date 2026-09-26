# Telemetry

What Camelot reports about itself, and the rules every event follows.

The driving question is the activation funnel: an external user signs
up, connects GitHub, adds a Claude token, creates a project and runs a
task. Before this, only the happy-path Ash actions were instrumented,
so a user who stopped anywhere in between was invisible — every
failure branch, the onboarding guide, the GitHub App connect flow and
credential setup were silent.

## Rules

1. **Every property is bounded.** Enums, booleans, ids and counts.
   Never `inspect/1` output, never a validation message, never
   anything a user typed. Unbounded property values make a PostHog
   funnel ungroupable.
2. **Every failure branch is an event.** A `{:error, reason}` that
   only reaches `Logger` is a drop-off nobody can see.
3. **Captures go through `Camelot.Telemetry.Capture`**, which merges
   the process's PostHog context and the global properties, and drops
   captures that have no `distinct_id` rather than creating anonymous
   people.
4. **Secrets never leave the box.** `Camelot.Accounts.Credential`
   events carry `kind`, never `value`.

## Modules

| Module | Responsibility |
|---|---|
| `Camelot.Telemetry.Notifier` | Ash notifier; emits `[:camelot, :ash, :notify]` for every notification on the resources that register it |
| `Camelot.Telemetry.PostHogHandler` | Transport and identity: attaches to the telemetry events, resolves the `distinct_id` |
| `Camelot.Telemetry.Events` | The catalogue: which Ash actions are events, and what each carries |
| `Camelot.Telemetry.Capture` | The only capture API; merges global + process properties |
| `Camelot.Telemetry.Context` | `environment` and `internal?/1` |
| `Camelot.Telemetry.Reason` | Error term → bounded `{reason, http_status}` |
| `Camelot.Telemetry.TaskFailure` | Failed task → bounded `{stage, reason}` |

## Global properties

Every capture, server-side and browser-side, carries:

| Property | Source |
|---|---|
| `environment` | `DEPLOYMENT_ENV` (`config :camelot, :telemetry`), mirroring the otel collector gateway. Defaults to the **non**-production value so an unset variable never invents production data |
| `is_internal` | `Camelot.Telemetry.Context.internal?/1` — true outside production, or for a maintainer email. Client domains are *not* internal |

Set `DEPLOYMENT_ENV=production` on the production CapRover app only;
the test cluster runs the same release, and leaving it unset is what
keeps staging traffic out of the funnel.

The browser gets both as PostHog super-properties
(`assets/js/posthog_client.js`), so autocaptured events —
`$pageview`, and the `$exception` volume nothing else tags — carry
them too. `CamelotWeb.TaskLive` additionally registers `task_id` /
`project_id` for the life of the page.

## Event catalogue

### Identity

| Event | Properties |
|---|---|
| `user_signed_up` | `auth_method` (`github \| magic_link \| invite`) |
| `user_signed_in` | `$set`: `email`, `role`, `auth_method`, `is_internal`; `$set_once`: `signed_up_at` |

`:register_with_github` and `:sign_in_with_magic_link` are upserts and
notify as creates on *every* login, so `user_signed_up` is gated on
the account having been inserted within the last 60 seconds. Ash
exposes no insert-vs-conflict flag; `inserted_at` is not in either
action's `upsert_fields`, so a returning user still carries their
original signup time and is correctly skipped.

### Onboarding guide

| Event | Properties |
|---|---|
| `onboarding_shown` | `steps_total`, `steps_done`, `next_step` |
| `onboarding_step_clicked` | `step` (`github \| claude_token \| project \| task`) |
| `onboarding_step_completed` | `step` |
| `onboarding_dismissed` | `steps_total`, `steps_done`, `next_step`, `via` (`close \| step_click`) |
| `onboarding_completed` | `steps_total`, `steps_done`, `next_step`, `duration_since_signup_s` |

`onboarding_shown` and `onboarding_step_completed` also set the person
properties `onboarding_next_step`, `github_connected`,
`has_claude_token`, `has_project`, `has_task`, so the "stuck at step
X" cohort is a person-property filter with no joins.

Clicking a step dismisses the guide as a side effect, so
`onboarding_dismissed` fires for the most engaged action the guide
offers as well as for genuine abandonment. `via` separates the two:
filter to `via = close` for the "gave up" cohort.

`onboarding_dismissed` and `onboarding_completed` are captured from
the `User` resource's notifier, which sees the user but not the
guide, so the guide's own numbers are handed over as *event-scoped*
PostHog context (`PostHog.set_event_context/2`). Event-scoped rather
than process-wide because `PostHog.Context` only ever merges and
cannot delete: a process-wide write would stamp one guide's
`steps_done` onto every later capture from the same LiveView process.

### GitHub App

| Event | Properties |
|---|---|
| `github_setup_started` | — |
| `github_setup_succeeded` | `installation_id`, `account_type`, `repository_selection` |
| `github_setup_failed` | `reason`, `http_status` |
| `github_installation_linked` | `installation_id` |
| `github_installation_suspended` / `_unsuspended` | `installation_id` |
| `project_repo_resolve_failed` | `reason`, `http_status` |

`reason` is a `Camelot.Telemetry.Reason` value:
`missing_state`, `not_authenticated`, `actor_mismatch`,
`invalid_state`, `expired_state`, `invalid_installation_id`,
`not_configured`, `no_installation`, `repo_not_in_installation`,
`not_found`, `forbidden`, `rate_limited`, `http_error`,
`transport_error`, `upsert_failed`, `link_failed`, `invalid_json`,
`invalid_integer`, `unknown`.

### Credentials

| Event | Properties |
|---|---|
| `claude_token_added` / `claude_token_removed` | `kind` |
| `credential_added` / `credential_removed` | `kind` |

`claude_token_*` is the funnel step; other kinds get the generic event
so an OpenAI key never arrives under a Claude-shaped name. The default
SSH key `Camelot.Accounts.User.Changes.EnsureDefaultSshKey` writes on
every signup is skipped — it is not something the user did.

### Projects, agents and tasks

| Event | Properties |
|---|---|
| `project_created` | `has_github_repo`, `has_github_installation` |
| `project_create_failed` | `error_fields`, `error_codes` |
| `agent_created` / `agent_updated` | `slug` |
| `task_created`, `task_started`, `task_plan_submitted`, `task_plan_approved`, `task_pr_created`, `task_completed`, `task_cancelled` | `data_id` |
| `task_form_blocked` | `reason` (`no_project \| no_agent`) |
| `task_errored` / `task_runner_lost` | `stage`, `reason` |

`project_create_failed.error_codes` are the short names of Ash error
structs (`required`, `invalid_attribute`, …) or, for the advanced
override fields, `not_json_object \| invalid_json \|
invalid_integer` — never the message, which would embed user input.

`task_errored.stage` ∈ `clone | boot | plan | execute | pr` and
`reason` ∈ `git_auth_failed | image_pull_failed | provision_failed |
agent_exit_nonzero | empty_plan | no_pr_url | interrupted | timeout |
unexplained`, classified by `Camelot.Telemetry.TaskFailure` from the
task's `stage` and `last_error`. Unrecognised wording degrades to
`unexplained` rather than leaking a string, so new runner failure
messages land there until a pattern is added.

## The funnel

```
user_signed_up
  → github_setup_succeeded
  → claude_token_added
  → project_created
  → task_created
  → task_pr_created
```

Filter on `environment = production` and `is_internal = false`.

## Structured logging

The released build logs JSON (`config/runtime.exs`), and these
metadata keys are emitted as fields rather than buried in the message:
`user_id`, `project_id`, `task_id`, `installation_id`, `reason`,
`http_status`.

They are set per process, so every log line from that process inherits
them: `CamelotWeb.LiveUserAuth.attach_posthog_hook/1` sets `user_id`,
`CamelotWeb.TaskLive` adds `task_id` / `project_id`, and
`Camelot.Runtime.TaskRunner` sets all three. Runner containers export
`CAMELOT_TASK_ID`, and `runner-images/base/entrypoint.sh` prints
`task_id=<uuid> stage=boot|clone` so the collector's container logs
join to a task.

## Testing

`config/test.exs` keeps PostHog enabled with `test_mode: true`, so
captures land in memory and `PostHog.Test.all_captured/0` can assert
on them. Captures made inside a LiveView process are not owned by the
test process — those tests use `setup_all {PostHog.Test,
:set_posthog_shared}` and `async: false` (see
`test/camelot_web/live/project_telemetry_test.exs`).

The catalogue is matched to actions by *name*, so renaming an action
or dropping a resource's notifier would take its event off the air
without breaking the build. `test/camelot/telemetry/events_test.exs`
guards both: every `{resource, action}` pair must resolve to a real
action on a resource that registers `Camelot.Telemetry.Notifier`.

## Not here yet

OpenTelemetry traces and application metrics (sections 2 and 3 of
GH#168) are a separate task. The collector gateway is up and waiting;
nothing in the app produces spans or app-level metrics yet.
