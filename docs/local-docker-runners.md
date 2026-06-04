# Running Camelot locally with Docker runners

This guide walks you through running the BEAM on your host but launching
each agent CLI inside a Docker container via the `DockerEngine` backend.
It's the fastest way to exercise the new cluster-runner code path
without standing up a Swarm.

For the multi-node Swarm story, see
[`cluster-runners.md`](cluster-runners.md).

## What you'll have at the end

- Camelot running in `iex -S mix phx.server` on your host.
- PostgreSQL in a container (existing `docker-compose.yml`).
- Every agent CLI dispatch spawns a one-shot `camelot-runner-<id>`
  container on your local Docker daemon.
- A working `/profile` page where you can add credentials and watch
  pool usage in real time.

## Prerequisites

- Docker Desktop running (or a working `docker` CLI against a local
  daemon).
- Elixir 1.19 / Erlang/OTP 28 (use `asdf` or `mise`).
- A clone of this repo with deps fetched:
  ```sh
  mix deps.get
  ```

## 1. Start the database

```sh
docker compose --profile db up -d
```

This brings up the `db` service from `docker-compose.yml` on port 5433.
The `.env` in the repo root supplies credentials.

Migrate:

```sh
mix ecto.migrate
```

## 2. Build at least one runner image

For a true end-to-end test (real agent), build the base + claude
images. Single-arch (matching your host) is fine for local dev:

```sh
docker build -t camelot/runner-base:dev runner-images/base
docker build \
  --build-arg BASE_IMAGE=camelot/runner-base:dev \
  -t camelot/runner-claude:dev runner-images/claude
```

For a faster smoke test that only verifies the runner-spawn / log-tail
/ exit-code wiring, skip the build and use a stock image:

```sh
docker pull alpine:latest
```

## 3. Start Camelot pointed at Docker

```sh
RUNNER_BACKEND=docker \
DOCKER_HOST=unix:///var/run/docker.sock \
RUNNER_PER_USER_MAX=2 \
RUNNER_GLOBAL_MAX=5 \
iex -S mix phx.server
```

The `RUNNER_BACKEND=docker` env var picks up
`Camelot.Runtime.Runner.DockerEngine`, which talks to
`/var/run/docker.sock` directly.

Verify:

```iex
iex> Camelot.Runtime.Runner.backend()
Camelot.Runtime.Runner.DockerEngine

iex> Camelot.Runtime.Runner.DockerApi.ping()
:ok
```

If `ping/0` returns an error, your `DOCKER_HOST` is wrong or the daemon
isn't reachable.

## 4. Sign in

Open <http://localhost:4000>. Sign in via magic link — the email lands
in the dev mailbox at <http://localhost:4000/dev/mailbox>.

## 5. Create an AgentTemplate

Use the smoke template (alpine) or the real one (claude). In an IEx
shell:

```iex
iex> Ash.create!(Camelot.Agents.AgentTemplate, %{
...>   slug: "alpine-echo",
...>   name: "Alpine smoke test",
...>   executable: "/bin/sh",
...>   base_args: ["-c", "echo hello; sleep 2; echo bye"],
...>   runner_image: "alpine:latest",
...>   runner_resources: %{"cpu" => "0.5", "memory" => "256M"},
...>   required_credential_kinds: [],
...>   parser: :raw_text,
...>   pr_url_pattern: "x^"
...> })
```

For Claude Code:

```iex
iex> Ash.create!(Camelot.Agents.AgentTemplate, %{
...>   slug: "claude_code",
...>   name: "Claude Code",
...>   executable: "claude",
...>   base_args: ["--print"],
...>   prompt_flag: nil,
...>   tools_flag: "--allowed-tools",
...>   runner_image: "camelot/runner-claude:dev",
...>   runner_resources: %{"cpu" => "1.0", "memory" => "1G"},
...>   required_credential_kinds: [:claude_api_key],
...>   parser: :claude_code_json,
...>   pr_url_pattern: "https://github\\.com/[^\\s]+/pull/(\\d+)"
...> })
```

(Or use the existing `/agent-templates/new` UI, then set
`runner_image` etc. via the form.)

## 6. Create a Project

Visit `/projects/new`. The DockerEngine backend reproduces the Swarm
flow exactly: it always clones `github_repo_url` into an ephemeral
`/workspace` tmpfs. So:

- Set `github_repo_url` to a clonable URL. Public repos work without
  extra credentials; private repos require a `github_pat` credential
  on the user.
- For the smoke test, leave it empty — the entrypoint will skip the
  clone and `/workspace` will be an empty tmpfs.

If you want to point at code already on your disk (no clone, no
container), switch the backend to LocalPort:

```sh
RUNNER_BACKEND=local iex -S mix phx.server
```

Then `path` on the project drives the BEAM's `cd` for the CLI.

## 7. Add credentials at /profile

Visit <http://localhost:4000/profile>:

- Add credentials for whatever the AgentTemplate's
  `required_credential_kinds` lists (e.g. `:claude_api_key`).
- (Optional) set your swarm node label — not used by the DockerEngine
  backend, but you can populate it now so the model is the same as the
  hosted setup.

> Note: when `RUNNER_BACKEND=docker`, secrets are passed to the
> container via env vars under `CAMELOT_SECRET_<KIND>` — Swarm secrets
> only kick in with `RUNNER_BACKEND=swarm`. The entrypoint inside the
> image reads from `/run/secrets/...` first; we'll likely add an env
> fallback there in a follow-up. For now this means:
> - **Alpine smoke test**: no credentials needed.
> - **Claude test**: pass the API key via the AgentTemplate's
>   `env_vars` map for now, e.g.
>   `env_vars: %{"ANTHROPIC_API_KEY" => "sk-..."}`, until env-fallback
>   lands.

## 8. Wire an Agent to a User

The `User → Agent → Project → Template` graph must be complete.
Backfill the `user_id` on agents (legacy rows allowed null user_id;
the migration didn't auto-fill):

```iex
iex> user = Ash.read_first!(Camelot.Accounts.User)
iex> agent = Ash.read_first!(Camelot.Agents.Agent)
iex> Camelot.Repo.update_all(
...>   Ecto.Query.from(a in Camelot.Agents.Agent, where: a.id == ^agent.id),
...>   set: [user_id: user.id]
...> )
```

(New agents created through the UI will need a `user_id` argument
passed to the create action.)

## 9. Dispatch a task and watch the container

Two terminals:

**Terminal 1** — watch container lifecycle:

```sh
watch -n 1 'docker ps --filter "name=camelot-runner-"'
```

**Terminal 2** — once a container appears, tail its logs:

```sh
docker logs -f $(docker ps -q --filter "name=camelot-runner-")
```

Then in the Camelot UI:

1. Open `/` (the board), create a new task on your project.
2. Drag it to "Todo".
3. The agent picks it up via the Oban `dispatch_tasks` job (runs every
   minute). To skip the wait, manually dispatch in IEx:
   ```iex
   iex> Camelot.Runtime.AgentSupervisor.start_agent(agent.id)
   iex> Camelot.Runtime.AgentProcess.dispatch(agent.id, task.id, "do something", [])
   ```

You should see:

- A `Session` row appear with `status: :queued`.
- A few moments later, `status: :running` and `service_id` populated.
- A `camelot-runner-<session_id>` container in `docker ps`.
- Output streaming into the LiveView task page in real time.
- On exit, container disappears, session marked `:completed` /
  `:failed`.

Verify the pool snapshot updates at `/profile`:

```
You — running: 0/2
You — queued:  0
Cluster:       0/5
```

## 10. Tear-down between tries

If something goes sideways and you have stuck containers:

```sh
docker ps -a --filter "name=camelot-runner-" -q | xargs -r docker rm -f
```

The `Reconciler` sweeps orphans automatically once per minute too, so
they'd be cleaned up regardless — but `-f` is faster.

To reset queued sessions in the DB after a hard restart:

```iex
iex> import Ecto.Query
iex> Camelot.Repo.update_all(
...>   from(s in Camelot.Agents.Session,
...>     where: s.status in [:queued, :running]
...>   ),
...>   set: [status: :cancelled, finished_at: DateTime.utc_now()]
...> )
```

## Troubleshooting

### `Camelot.Runtime.Runner.backend/0` returns `LocalPort`

You forgot `RUNNER_BACKEND=docker` in front of `iex -S mix phx.server`.
Quit (`Ctrl+C` twice) and relaunch with the env var prefix.

### `DockerApi.ping()` returns `{:error, _}`

- `DOCKER_HOST=unix:///var/run/docker.sock` is the default. On Docker
  Desktop for Mac this socket is the *host's* socket, exposed at the
  same path. If it's not there, set it to wherever Docker Desktop
  exposes it (check `docker context inspect`).
- For a remote daemon set `DOCKER_HOST=tcp://host:2375`.

### Container starts then exits immediately with no logs

- Check `docker inspect <name>` — the `State.Error` field usually
  explains it.
- For `alpine:latest`, make sure the AgentTemplate's `executable` is
  something that actually exists in the image (`/bin/sh`, not
  `claude`).

### Session never transitions out of `:queued`

- `RunnerPool` may be at its `per_user_max` cap. Check `/profile`.
- The pool monitors the AgentProcess pid — if your IEx node restarted,
  the monitor fires and the slot frees, but the queued sessions may
  still be in the DB. Run the DB reset from step 10.

### Logs not streaming into the LiveView

- LocalPort uses `Phoenix.PubSub` topic `agent:<agent_id>` — same as
  DockerEngine. Verify the LiveView subscribes there. If you wired in
  custom UI, double-check.

### "Cannot pull camelot/runner-claude:dev"

You only built it locally — there's no registry to pull from. Make
sure `runner_image: "camelot/runner-claude:dev"` matches exactly the
tag you built (case sensitive). Docker won't auto-pull tags that don't
exist remotely.

## Going further

When you're done with single-node local testing and want to exercise
the Swarm backend:

```sh
docker swarm init
docker node update --label-add camelot-home=local $(docker node ls -q)
# Set User.swarm_node_label = "local"
RUNNER_BACKEND=swarm iex -S mix phx.server
```

Everything else stays the same. See
[`cluster-runners.md`](cluster-runners.md) for the full hosted-mode
setup.
