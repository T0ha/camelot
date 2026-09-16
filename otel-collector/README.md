# OpenTelemetry collector

Cluster telemetry pipeline. Two components, both plain upstream
`otel/opentelemetry-collector-contrib` images with a config baked in, so
the config is versioned and reviewed like any other code.

```
   every node                          one node
 ┌──────────────────────┐          ┌──────────────────┐
 │ otel-agent (global)  │          │ otel-gateway     │
 │  container logs      │  OTLP    │                  │ logs+traces  PostHog
 │  node metrics        │ ───────► │  the only place  │ ───────────►
 │  container metrics   │  gRPC    │  holding vendor  │ metrics      Better Stack
 └──────────────────────┘          │  credentials     │ ───────────►
   Camelot backend  ──────────────►│                  │
   (traces, later)      OTLP       └──────────────────┘
```

The agent has to run on every node because container logs are read off
each node's own disk — a single central collector cannot see other
nodes' logs. The gateway exists so credentials live in exactly one
place and the backend has one stable endpoint to push traces at.

## What is collected

| Signal  | Source                                   | Destination  |
|---------|------------------------------------------|--------------|
| Logs    | every container, via `docker_observer` + one `filelog` receiver per container | PostHog |
| Metrics | `host_metrics` (CPU, memory, disk, network, load, paging, processes) | Better Stack |
| Metrics | `docker_stats` per container, labelled with its swarm service and task | Better Stack |
| Traces  | OTLP in on 4317/4318 — nothing produces them yet; the backend will | PostHog |

Every log record carries `host.name` (the swarm node), `container.name`,
`container.id`, `container.image.name` and `service.name`. For swarm
containers `service.name` is the swarm service (`srv-captain--camelotai`,
`camelot-task-<uuid>`, …); everything else falls back to the container
name.

**The swarm service is named differently per signal**, which matters when
building dashboards that span both:

| Signal  | Attribute            | Kind               |
|---------|----------------------|--------------------|
| Logs    | `service.name`       | resource attribute |
| Metrics | `docker.service.name` | metric label      |

Metrics additionally carry `docker.task.name` and `docker.node.id`, which
logs do not. They are kept distinct rather than aligned because
`service.name` is a resource-level convention, and forcing it onto
`docker_stats` data points would misrepresent a per-container metric as a
per-service one.

## Deploying

`.github/workflows/deploy-otel-collector.yml` builds both images
multi-arch and deploys them on pushes to `develop` that touch this
directory. It is gated on the `test` environment variable
`DEPLOY_OTEL_COLLECTOR=true`, so it no-ops until the CapRover apps below
exist.

### 1. CapRover apps

Create two apps, both with **Do not expose as web app** checked — they
talk only over `captain-overlay-network` and publish no host ports.

**`otel-gateway`** — single replica. Under *Service Update Override*:

```yaml
TaskTemplate:
    Placement:
      Constraints:
        - node.labels.otel_role == gateway
    Resources:
      Limits:
        MemoryBytes: 402653184
      Reservations:
        MemoryBytes: 134217728
```

Pinned by node label rather than hostname, because placement here floats
and the manager is a 1 GB node. The node carrying the gateway needs
roughly **1 GB free** — it runs the 384 MiB gateway *and* its own 256 MiB
agent, on top of whatever else it is scheduled. Label it:

```sh
docker node update --label-add otel_role=gateway vmic-camelotai-arm-01
```

**`otel-agent`** — one per node. Under *Service Update Override*:

```yaml
Mode:
    Global: {}
TaskTemplate:
    ContainerSpec:
      Mounts:
        - Source: /var/run/docker.sock
          Target: /var/run/docker.sock
          Type: bind
          ReadOnly: true
        - Source: /var/lib/docker/containers
          Target: /var/lib/docker/containers
          Type: bind
          ReadOnly: true
        - Source: /
          Target: /hostfs
          Type: bind
          ReadOnly: true
        - Source: /var/lib/otelcol-agent
          Target: /var/lib/otelcol/storage
          Type: bind
    Resources:
      Limits:
        MemoryBytes: 268435456
      Reservations:
        MemoryBytes: 67108864
```

`Mode: Global: {}` is how the existing `docker-socket-proxy` app runs on
every node; CapRover's instance count is ignored once it is set.

The mounts are all read-only except the offset directory. `/` at
`/hostfs` is what `host_metrics` measures — without it the scrapers
describe the collector's own container instead of the node.

Pre-create the offset directory on every node, so a missing path cannot
hold up a task:

```sh
sudo mkdir -p /var/lib/otelcol-agent
```

### 2. App environment variables

On **`otel-gateway`**:

| Variable | Value |
|----------|-------|
| `POSTHOG_PROJECT_API_KEY` | project token, `phc_…` — *not* a personal API key |
| `POSTHOG_HOST` | `https://us.i.posthog.com` or `https://eu.i.posthog.com` |
| `BETTERSTACK_INGEST_URL` | the source's ingesting host, `https://<id>.betterstackdata.com` |
| `BETTERSTACK_SOURCE_TOKEN` | source token from the Better Stack dashboard |
| `DEPLOYMENT_ENV` | `test` (tags everything, so test and prod stay apart in one PostHog project) |

On **`otel-agent`**: nothing is required. `OTEL_GATEWAY_ENDPOINT`
defaults to `srv-captain--otel-gateway:4317`, and `OTEL_LOG_LEVEL`
to `warn`.

If you deploy the gateway under a different name via
`OTEL_GATEWAY_APP_NAME`, its CapRover service becomes
`srv-captain--<that name>` and the agent's default stops resolving — set
`OTEL_GATEWAY_ENDPOINT` on the agent app to match, or the agents export
into nothing.

### 3. GitHub configuration

`test` environment secrets: `OTEL_GATEWAY_APP_TOKEN`,
`OTEL_AGENT_APP_TOKEN` (CapRover app deploy tokens).
`test` environment variables: `DEPLOY_OTEL_COLLECTOR=true`, and
optionally `OTEL_GATEWAY_APP_NAME` / `OTEL_AGENT_APP_NAME` if the apps
are not named `otel-gateway` / `otel-agent`.

## Sending traces from the backend

The gateway accepts OTLP on `srv-captain--otel-gateway:4317` (gRPC) and
`:4318` (HTTP), no TLS and no auth — it is only reachable from inside
the overlay network. Point the app's exporter there; the gateway adds
`deployment.environment.name` and forwards to PostHog.

## Verifying

```sh
# one agent task per node, gateway on the labelled node
docker service ps srv-captain--otel-agent srv-captain--otel-gateway

# export failures show up here; healthy collectors are quiet at warn level
docker service logs --tail 50 srv-captain--otel-gateway
```

Raise `OTEL_LOG_LEVEL` to `info` on either app to see pipeline activity.

## Notes and caveats

- **First start ships a backlog.** Each container is read from the top
  the first time it is seen, so its startup logs are not lost. Offsets
  are checkpointed to `/var/lib/otelcol/storage`, so this happens once,
  not on every restart. At the time of writing the existing backlog was
  ~106 MB on the manager and ~41 MB on the arm node. The gateway's send
  queue is in memory and bounded (1000 batches), so a vendor outage
  lasting past that point drops the oldest data rather than growing
  without limit. Surviving a longer outage would need a disk-backed
  queue, which needs another mount — not worth it for test.
- **Docker has no log rotation configured here** (no `/etc/docker/daemon.json`),
  so container logs grow without bound. That is a pre-existing disk
  issue rather than one this pipeline creates, but it also sets the size
  of the first-start backlog. Adding `max-size`/`max-file` to the daemon
  config would bound both — it needs a `dockerd` restart per node.
- **The agent excludes both collector images** from discovery. Without
  that it tails its own log, and anything it prints about a log record
  becomes another log record. The gateway is excluded for the same
  reason in reverse: a failing export makes it log, and shipping that
  log back through it amplifies the failure it is reporting. Both stay
  readable with `docker service logs`.
- **The agent runs as root** (the upstream image runs as uid 10001)
  because the docker socket and the container log directory are
  root-owned on the host. The gateway keeps the unprivileged user.
- **Corrupt log lines are forwarded, not dropped.** A disk-full event on
  2026-09-02 left a handful of truncated, spliced-together records in
  these files, and docker will do it again the next time a node fills
  up. The container parser is set to `on_error: send_quiet`, so what it
  cannot parse still reaches PostHog as a raw line instead of becoming
  one collector error per occurrence.
- **Agent memory was sized by measurement, not by guess.** At
  `limit_mib: 128` the limiter refused data throughout the first-start
  backlog; at 160 a real node settles around 137 MiB with nothing
  refused. The filelog receivers also retry rather than drop, so if the
  limiter ever does bite they stop reading and wait.
- **Short-lived containers may be missed.** Discovery happens on a
  docker event, so a container that starts and exits within roughly a
  second can be gone before its receiver starts.
- The nodes are small and already OOM-prone, so `memory_limiter` is
  first in every pipeline and both services have swarm memory limits.
