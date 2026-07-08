# Cluster runners deployment guide

Camelot runs every agent CLI inside an isolated container scheduled by
Docker Swarm. This guide covers what an operator needs to set up.

## TL;DR

For a hosted CapRover deployment:

1. Run `tecnativa/docker-socket-proxy` as a Swarm service on the manager,
   exposing only `SERVICES`, `TASKS`, `NETWORKS`, `NODES`, `SECRETS`.
2. Label worker nodes with `camelot-home=node-X` for every X you want
   to host user runner containers on.
3. Set Camelot's env vars (CapRover app config):
   - `RUNNER_BACKEND=swarm`
   - `DOCKER_HOST=tcp://docker-socket-proxy:2375`
   - `ENCRYPTION_KEY=<32-byte base64>`
   - `RUNNER_GLOBAL_MAX=20` (or whatever your cluster can handle)
   - `RUNNER_PER_USER_MAX=2` (default tier)
   - `RUNNER_NETWORKS` — optional; defaults to `auto` (see *Runner
     networking*). Set `none` to keep runners isolated.
4. Build and push the runner images
   (`.github/workflows/runner-images.yml`). Reference them from
   `AgentTemplate.runner_image`.
5. For each user, in Camelot's profile UI:
   - Add their API keys / GitHub PAT as Credentials.
   - Set their `swarm_node_label` (admin-only) to the node label you
     want their runners pinned to. `SecretSync` will populate
     `camelot_user_<id>_<kind>` Swarm secrets automatically.

## Deployment topologies

Camelot does *not* require running on a manager. Three supported
shapes:

### A. Local socket (smallest installs)

```
manager + camelot
  /var/run/docker.sock ─bind-mount─► camelot
```

Camelot scheduled onto a manager, the manager's socket mounted in.
`DOCKER_HOST=unix:///var/run/docker.sock`. Simplest, but Camelot can
only ever run on a manager.

### B. Remote TCP + TLS (max flexibility)

```
manager           camelot (anywhere)
 dockerd ──tcp/2376─► REQ
   (mTLS)
```

Daemon configured with `tcp://0.0.0.0:2376` + client cert auth.
Camelot env: `DOCKER_HOST=tcp://<manager>:2376` plus `DOCKER_CERT_PATH`
mounted as a Swarm secret. Lets Camelot live anywhere reachable.

### C. Socket proxy as a Swarm service (recommended)

```
manager (proxy)             camelot (anywhere)
  socket ──► docker-socket-proxy ──tcp/2375─► Camelot
```

Proxy service constrained to managers; Camelot reaches it via the
in-cluster overlay network. Survives Camelot getting rescheduled to a
worker, restricts the API surface, and Swarm handles proxy failover.

Example proxy service:

```
docker service create \
  --name docker-socket-proxy \
  --network camelot \
  --constraint node.role==manager \
  --mount type=bind,src=/var/run/docker.sock,dst=/var/run/docker.sock \
  --env SERVICES=1 --env TASKS=1 --env NODES=1 \
  --env NETWORKS=1 --env SECRETS=1 \
  tecnativa/docker-socket-proxy:latest
```

Camelot env: `DOCKER_HOST=tcp://docker-socket-proxy:2375`.

## Node labels

User runners are scheduled with a placement constraint so a user's
volume stays local (no NFS required). Label each candidate worker:

```
docker node update --label-add camelot-home=node-a worker-1
docker node update --label-add camelot-home=node-b worker-2
```

Then set the same label string on each User row (`swarm_node_label`)
through Camelot's admin UI.

## Pool capacity

| Env var | Default | What it controls |
|---|---|---|
| `RUNNER_GLOBAL_MAX` | 20 | Cluster-wide concurrent runner count. |
| `RUNNER_PER_USER_MAX` | 2 | Free-tier cap per user. Override per user via `RunnerPool.set_user_cap/2`. |

Sessions never get refused — they queue. Wait time surfaces in the UI;
a future paid tier will let users buy higher per-user caps.

## Runner networking

A task-runner container joins the Swarm bridge network for outbound
internet, but Swarm's service-discovery DNS (e.g. a CapRover
`srv-captain--db`) only resolves between containers on the same
*overlay*. A runner that runs the project's test suite against a shared
database — `DATABASE_URL=ecto://…@srv-captain--db:5432/…` — needs to be
on that overlay, or it fails with *"Name or service not known"* /
`nxdomain`.

`RUNNER_NETWORKS` controls which overlays runners join.

| Value | What happens |
|---|---|
| *(unset)* / `auto` | **Default.** Camelot copies the overlay network(s) its *own* service is on onto each runner. |
| `net-a,net-b` | Explicit network names/IDs. Combine with `auto` (`auto,net-a`) to add to the discovered set. |
| `none` | Keep runners isolated — bridge only, no overlay. |

**`auto` (the default)** — a runner reaches exactly what Camelot
reaches, with nothing to hardcode. Discovery reads the app's own task and
service via the Docker API (`TASKS` + `SERVICES`, already in the
socket-proxy allow-list) and memoizes the result. If it can't complete
(e.g. plain-Docker / non-Swarm self-hosting, where there is no overlay to
discover), runners start with no extra network and a warning is logged —
never a hard failure.

**Security note:** `auto` places runners on the same overlay as Camelot,
so they can reach the control-plane services on it (including Camelot's
own DB). Set `RUNNER_NETWORKS=none` — or an explicit, dedicated overlay —
if you need runners isolated from the control plane.

## Backups & disaster recovery

- **DB is the source of truth.** Back up PostgreSQL.
- **Profile volumes are caches.** Losing one only costs the next
  session's bootstrap time (asdf re-install, CLI caches rebuilt). The
  entrypoint re-materialises credentials from secrets on every spawn.
- **Swarm secrets**: rotate via Camelot UI (or
  `SecretSync.reconcile/2`); no manual `docker secret` calls needed.

## Local development

Drop `RUNNER_BACKEND=local` (the default in dev/test). Camelot runs
the CLI directly on your host via `Port.open` — identical to the
pre-runner behaviour. No Docker required.

To test the containerised path on a dev VM without Swarm:
`RUNNER_BACKEND=docker`. Set up a Docker daemon and bind-mount the
socket (or expose it over TCP).
