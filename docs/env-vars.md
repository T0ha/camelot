# Runner environment variables

Camelot injects custom environment variables into a project's
runner containers via the `Camelot.Projects.EnvVar` resource.
This is where project infrastructure config lives — a Postgres
URL, NATS connection details, feature-flag endpoints, and the
like — separate from the CLI/agent behaviour configured on an
`AgentTemplate`.

## Scopes and precedence

Each `EnvVar` row attaches to **exactly one** scope, or to none
(a global default):

| Scope   | Column set   | Applies to                         |
| ------- | ------------ | ---------------------------------- |
| project | `project_id` | every runner for that project      |
| agent   | `agent_id`   | one agent                          |
| user    | `user_id`    | every agent owned by that user     |
| global  | (all NULL)   | every runner                       |

When the same key is defined at more than one scope for a given
runner, the most specific wins, in this order:

```
project > agent > user > global
```

Resolution and merging happen in
`Camelot.Runtime.EnvVarResolver.resolve/1`, whose output is
merged into the runner `Spec` env in
`Camelot.Runtime.AgentProcess.build_spec/5`. The `EnvVar` layer
is merged last, so it overrides any colliding key inherited from
`AgentTemplate.env_vars` / `Agent.env_vars_override`.

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
`{:agent, id}`, `{:user, id}`, or `:global`.

## Uniqueness

A key is unique within its scope, enforced by partial unique
indexes (one per scope) so it works on PostgreSQL < 15 where
`NULLS NOT DISTINCT` is unavailable. The same key may exist in
different projects, or at different scopes.
