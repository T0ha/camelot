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
| `environment` | `DEPLOYMENT_ENV` (`config :camelot, :telemetry`), the same variable *and the same unset default* as the otel collector gateway (`${env:DEPLOYMENT_ENV:-test}`) |
| `is_internal` | `Camelot.Telemetry.Context.internal?/1` — true outside production, or for a maintainer email. Client domains are *not* internal |

Set `DEPLOYMENT_ENV=production` on the production CapRover app only.
Both clusters run the same `MIX_ENV=prod` release, so `config_env()`
cannot tell them apart and is deliberately *not* the fallback: it
would label staging and production alike, leaving the shared PostHog
project as mixed as it was before this existed, with
`environment = production` matching nothing. Unset means `test`,
which is also what the collector reports for the same box — so a
PostHog capture and its OTLP data name the same cluster.
`config/runtime.exs` and `otel-collector/gateway.yaml` are pinned to
each other by a test in `test/camelot/telemetry/context_test.exs`.

The browser gets both as PostHog super-properties
(`assets/js/posthog_client.js`), so autocaptured events —
`$pageview`, and the `$exception` volume nothing else tags — carry
them too. A LiveView can add page context on top by pushing
`posthog:register` — `CamelotWeb.TaskLive` sends `task_id` /
`project_id`, which is what makes an exception on a task page
attributable. PostHog persists registered properties, so page context
must not outlive the page — otherwise the first task a browser opens
tags everything it sends afterwards. `posthog_client.js` therefore
unregisters it on the way *out* of a page, before the next one mounts:
on `phx:page-loading-start{kind: "redirect"}` (link clicks and server
`push_navigate`, where `phx:navigate` arrives only after the
replacement view has already joined and registered its own context),
on `phx:navigate{pop: true}` (back/forward), and again on the
following page load. A `patch` stays inside the same LiveView and is
left alone.

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

`:sign_in_with_magic_link` is *generated* by AshAuthentication, so its
`upsert_fields` (`[:email]` today) is not ours to keep correct. Widen
it — or this repo's `[:github_user_id]` — to include `inserted_at` and
`user_signed_up` starts firing on every login, making the funnel's
first step a silent copy of `user_signed_in`. Both actions are pinned
by `test/camelot/telemetry/post_hog_handler_test.exs`, which asserts
the `upsert_fields` directly *and* drives a real returning login.

A notifier-driven capture is attributed to the action's actor, except
when the notification's subject *is* a user — then it is attributed to
that user. Both `:create_user` call sites (the admin screen and a
project invite) pass the inviter as the actor, so the exception is
what keeps an invited account's `user_signed_up` on the invitee: a
returning login is an upsert and never re-emits it, so crediting the
inviter would leave the invited account outside the funnel's first
step permanently, and count the inviter as signing up once per invite.

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

Those two events are not enough on their own to keep the cohort
honest, so **every connected mount with onboarding outstanding
restates them**, as a bare `$set` — PostHog's own person-update event,
which carries no product meaning and so stays out of the funnels built
on the events around it. Both of the other writers stop for exactly
the users who engage with the guide:

* clicking a step dismisses the guide, and a dismissed guide never
  auto-opens again, so `onboarding_shown` stops;
* three of the four steps finish across a navigation or a full page
  redirect — GitHub connect redirects to `/profile`, project creation
  `push_navigate`s — so the next mount recomputes the status from
  scratch and `refresh/1` has no `false -> true` flip left to see.

Without the restatement those users would show as stuck at a step they
had already finished. `onboarding_step_completed` still only fires on
a flip the hook actually observes, which needs the step to complete in
the same LiveView process: `/profile` and the board both nudge the
guide with `send(self(), {:onboarding, :refresh})` after completing
one — the convention `AGENTS.md` documents.

Re-opening the guide from the setup strip captures `onboarding_shown`
too; it is the only impression a dismissed guide can still produce.

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

`project_repo_resolve_failed` also has two capture points, for the two
ways a repository can turn out to be unreachable.
`Camelot.Github.RepositoryCatalog` reports the picker's view — an
installation whose repository listing errored (`http_status` set), or
no installation at all. `CamelotWeb.ProjectLive.Index` reports the
saved project's own owner, on create **and** on update, since the
`:update` action accepts `github_owner` too.

That second one is `repo_not_in_installation`, and it is the answer to
a failure that used to surface only as `[entrypoint] cloning …
Authentication failed` on a task page. The form accepts any
`github_repo_url`; `Camelot.Github.Resolver.installation_id/2` then
falls back to the sole installation when nothing matches the owner's
login, so the runner mints a token for an account that does not hold
the repository and the clone is rejected. `Resolver.owner_coverage/2`
deliberately has no such fallback — it answers whether the owner was
ever installed, which is the question a drop-off needs — and a
suspended installation is not coverage, matching what "connected"
means in `CamelotWeb.Onboarding` and `RepositoryCatalog`.

So a `task_errored` with `stage: clone, reason: git_auth_failed` is
expected to have a `project_repo_resolve_failed` with `reason:
repo_not_in_installation` against the same project behind it; the pair
is what turns that error alert into a cause.

`github_setup_succeeded` has two capture points, because GitHub can
be connected two ways. `CamelotWeb.GithubSetupController` handles the
profile's "Connect GitHub App" round-trip, and
`Camelot.Github.UserInstallations` handles the login one — a
first-time GitHub sign-in lands on the board already connected, with
no second step on /profile, which is the *intended* path. Reporting
only the first would have shown everyone who took the intended path
as a drop-off at the funnel's GitHub step.

The login path runs on **every** GitHub login, so it reports only a
link it actually made: an installation already owned by this user
emits nothing, and the `:link_user` Ash update is skipped so
`github_installation_linked` counts links rather than logins.

For the same reason `github_setup_failed` is reported **once per
sync**, and only when the sync left the user with no installation of
their own — neither newly linked nor already theirs. GitHub's
`/user/installations` keeps returning an org installation another
Camelot account owns, so a capture per payload would re-report the
same unclaimable installation at every login, and would report a user
who linked their own installation in that very sync as connected and
failed at once. Each skipped installation is still logged
individually (`info`, with its `installation_id`) — that is what the
log line is for.

The login path can also fail *before* any of that, when
`GET /user/installations` itself errors — a 5xx, a rejected token, or
the 10 s timeout the login critical path caps GitHub at. Nothing is
linked and nothing is skipped, so the per-sync report above has no
outcomes to look at; `Camelot.Github.UserInstallations.sync/2` reports
`github_setup_failed` for the listing in its own right. Two listing
errors deliberately report nothing, because neither is a connect the
user attempted: `not_configured` (the deployment has no GitHub App)
and `no_access_token` (the login carried no user token). That is the
same split `CamelotWeb.AuthController` makes when deciding which sync
failures are worth logging.

`reason` is a `Camelot.Telemetry.Reason` value:
`missing_state`, `not_authenticated`, `actor_mismatch`,
`invalid_state`, `expired_state`, `invalid_installation_id`,
`missing_installation_id`, `not_configured`, `no_installation`,
`repo_not_in_installation`,
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
| `project_created` | `has_github_repo`, `has_github_installation`, `repo_visibility` |
| `project_create_failed` | `error_fields`, `error_codes` |
| `agent_created` / `agent_updated` | `slug` |
| `task_created`, `task_started`, `task_plan_submitted`, `task_plan_approved`, `task_pr_created`, `task_completed`, `task_cancelled` | `data_id` |
| `task_form_blocked` | `reason` (`no_project \| no_agent`) |
| `task_errored` / `task_runner_lost` | `stage`, `reason` |

`project_created.has_github_installation` asks only whether the
creator had *any* live installation — not whether it covers this
project's repository. The two disagree often enough to matter: a user
installed on their personal account who points a project at an org
repo gets `has_github_installation: true` and a
`project_repo_resolve_failed` with `repo_not_in_installation`.

"Any live installation" still means *the creator's own*, and suspended
does not count — the same reading of "connected" that `Onboarding`,
`RepositoryCatalog` and `Resolver` use. A property that were true
whenever anybody had connected the App would report the whole cohort
as equipped, which is the opposite of what this event is for, so the
tests pin it from both ends: another user's installation and a
suspended one must both read `false`.

`project_created.repo_visibility` ∈ `public | private | internal`, or
`nil` when it is not known. A private repository the App was never
granted is the documented route to `[entrypoint] cloning …
Authentication failed`, so it is worth telling apart from a public one
at the point the project is made rather than when its first task dies.

It is `nil` more often than the others, and deliberately so. The
`Project` record does not store visibility and the event is captured
from the resource's notifier, so the only source is the repository
picker (`Camelot.Github.Client.normalize_repository/1`): a repository
typed straight into `github_repo_url` reports `nil`, as does one
picked and then edited before submitting. Reporting the last pick
regardless would attach a fact about one repository to another —
`nil` says "not known", which is true.

Carried across on `PostHog.set_event_context/2`, written on *every*
create including when it is unknown. `PostHog.Context` only ever
merges, so a project submitted after a rejected one in the same
LiveView would otherwise inherit whatever was picked before it; the
test suite pins that case.

`project_create_failed.error_codes` are the short names of Ash error
structs (`required`, `invalid_attribute`, …) or, for the advanced
override fields, `not_json_object \| invalid_json \|
invalid_integer` — never the message, which would embed user input.

`task_errored.stage` ∈ `clone | boot | plan | execute | pr` and
`reason` ∈ `git_auth_failed | image_pull_failed | provision_failed |
runner_died | agent_exit_nonzero | empty_plan | empty_output |
interrupted | timeout | unexplained`, classified by
`Camelot.Telemetry.TaskFailure` from the task's `stage` and
`last_error`. Unrecognised wording degrades to `unexplained` rather
than leaking a string, so new runner failure messages land there
until a pattern is added.

Each reason maps to a message `Camelot.Runtime.TaskRunner` or
`Camelot.Board.Interruption` actually writes — they are the only two
writers of `last_error`:

| `reason` | Written when |
|---|---|
| `git_auth_failed` | the entrypoint's clone could not authenticate |
| `image_pull_failed` | the runner image could not be pulled |
| `provision_failed` | no runner could be started for the task |
| `runner_died` | the runner exited before streaming any output |
| `agent_exit_nonzero` | the agent exited non-zero with no reason |
| `empty_plan` | a planning run produced no plan |
| `empty_output` | the agent produced no output (after its retries) |
| `interrupted` | a run was interrupted, or hit the re-queue cap |
| `timeout` | a run exceeded its time budget |

`task_failure_test.exs` pins this table from both ends: each of those
messages must classify, and each advertised reason must be reachable
from one of them. A reason nothing can produce is documentation for a
failure that cannot happen, and re-wording a runner message without
re-classifying it silently moves that failure into `unexplained` —
both fail the test rather than the funnel.

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
`Camelot.Runtime.TaskRunner` sets all three.

"Per process" is only the same as "per request" once something resets
it. `CamelotWeb.Plugs.RequestContext` is that reset, and it is not
optional: a LiveView's *dead render* runs in the connection process,
and Bandit keeps one process per TCP connection, looping over every
keep-alive request on it. Nothing in Plug, Phoenix or LiveView clears
`Logger` metadata between those requests, so without the plug the last
page a browser loaded tags everything it asks for afterwards — a
GitHub connect failure filed under whichever task the user looked at
first, an anonymous request still carrying the id of a user who has
signed out.

The same plug clears the PostHog context, for the same reason and one
worse: `PostHog.Context` has no delete at all, it only ever merges.
`CamelotWeb.LiveUserAuth` writes `$current_url` into the *instance*
scope, which `PostHog.Context.get/2` merges after the `:all` scope
`PostHog.Integrations.Plug` sets for the request in hand — so a stale
value does not just linger, it wins. The plug runs before
`PostHog.Integrations.Plug`, which then repopulates the context for
this request. `test/camelot_web/request_context_test.exs` pins both
halves: the page tags its own request, and the next request on the
same process is free of it.

Runner containers export `CAMELOT_TASK_ID`, and
`runner-images/base/entrypoint.sh` prints
`[camelot] task_id=<uuid> stage=boot|clone` so the collector's
container logs join to a task. That prefix is not `[entrypoint] `,
and the difference is load-bearing:
`Camelot.Runtime.Runner.Swarm.ProvisionMonitor.entrypoint_line/1`
takes the last `[entrypoint] ` line and `workspace_progress/1` renders
it into the task page verbatim, so metadata put on one of those lines
is shown to the user as their progress line. `log_stage` is for the
collector, `log` is for the person watching the task.

A capture is not automatically a warning. `project_repo_resolve_failed`
with `reason: no_installation` is the ordinary state of a user who has
not connected GitHub yet — it is an event, because that is where the
funnel stalls, but it logs at `info`. Only reasons that describe
something actually going wrong log at `warning`.

## Testing

`config/test.exs` keeps PostHog enabled with `test_mode: true`, so
captures land in memory and `PostHog.Test.all_captured/0` can assert
on them. Captures made inside a LiveView process are not owned by the
test process — those tests use `setup_all {PostHog.Test,
:set_posthog_shared}` and `async: false` (see
`test/camelot_web/live/project_telemetry_test.exs`).

In shared mode the stash belongs to the `setup_all` process, so it
**accumulates across every test in the module** and is ordered
newest-first. Finding one event by name is therefore safe, but a
`refute` or a count is not: those must also match the user the test
is about, or they assert over the whole file.

The catalogue is matched to actions by *name*, so renaming an action
or dropping a resource's notifier would take its event off the air
without breaking the build. `test/camelot/telemetry/events_test.exs`
guards both: every `{resource, action}` pair must resolve to a real
action on a resource that registers `Camelot.Telemetry.Notifier`.

## Not here yet

OpenTelemetry traces and application metrics (sections 2 and 3 of
GH#168) are a separate task. The collector gateway is up and waiting;
nothing in the app produces spans or app-level metrics yet.
