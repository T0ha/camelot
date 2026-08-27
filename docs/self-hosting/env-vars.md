%{
  title: "Environment variables",
  description: "Inject per-project environment variables into runners.",
  order: 3,
  published: true
}
---
# Runner environment variables

🏰 Camelot AI injects custom environment variables into a project's
runner containers via the `Camelot.Projects.EnvVar` resource.
This is where project infrastructure config lives — a Postgres
URL, NATS connection details, feature-flag endpoints, and the
like — separate from the CLI/agent behaviour configured on an
`Agent` (Agent CLI).

## Scopes and precedence

Each `EnvVar` row attaches to **exactly one** scope, or to none
(a global default):

| Scope   | Column set   | Applies to                         |
| ------- | ------------ | ---------------------------------- |
| project | `project_id` | every runner for that project      |
| agent   | `agent_id`   | every task run with that Agent CLI, across projects |
| user    | `user_id`    | every runner spawned for tasks owned by that user |
| global  | (all NULL)   | every runner                       |

When the same key is defined at more than one scope for a given
runner, the most specific wins, in this order:

```
project > agent > user > global
```

Resolution and merging happen in
`Camelot.Runtime.EnvVarResolver.resolve/3` (agent id, project id,
user id), whose output is merged into the runner `Spec` env in
`Camelot.Runtime.TaskRunner.build_spec/4`. The `EnvVar` layer
is merged last, so it overrides any colliding key inherited from
`Agent.env_vars` (the Agent CLI's own defaults) or
`Project.env_vars_override` (the project-wide override, which now
lives on `Project` rather than on a per-project agent row).

Because `spec.env` is the single source every backend turns into
the container's create-time `Env` (and every `docker exec`
inherits that), the values are visible to both container-start
and per-session exec, on all backends (Swarm, DockerEngine,
LocalPort). Credential rotation is picked up on the next runner
(next task/session), not live.

## Encryption

Values are **always encrypted at rest** via `AshCloak` against
`Camelot.Vault` (same mechanism as `Camelot.Accounts.Credential`).
The `secret` boolean does **not** change storage — it only marks
a value as sensitive so the UI masks it (`••••`) and it is kept
out of logs. Non-secret values (e.g. a hostname) are shown in the
editor; secret values (passwords, tokens) are masked.

## Editing

The reusable `CamelotWeb.Components.EnvVarEditor` LiveComponent
renders a scoped key/value editor. It is embedded on the project
page today:

```elixir
<.live_component
  module={CamelotWeb.Components.EnvVarEditor}
  id="project-env-vars"
  scope={{:project, @project.id}}
/>
```

The same component drives the other scopes by passing
`{:agent, id}` (keyed by the Agent CLI's id), `{:user, id}`, or
`:global`.

## Uniqueness

A key is unique within its scope, enforced by partial unique
indexes (one per scope) so it works on PostgreSQL < 15 where
`NULLS NOT DISTINCT` is unavailable. The same key may exist in
different projects, or at different scopes.
