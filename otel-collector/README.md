# OpenTelemetry collector

Cluster telemetry pipeline. Two components, both plain upstream
`otel/opentelemetry-collector-contrib` images with a config baked in, so
the config is versioned and reviewed like any other code.

```
   every node                          one node
 ┌──────────────────────┐          ┌──────────────────┐
 │ otel-agent (global)  │          │ otel-gateway     │
 │  container logs      │  OTLP    │                  │  logs
 │  node metrics        │ ───────► │  the only place  │  traces      PostHog
 │  container metrics   │  gRPC    │  holding vendor  │  metrics ───────────►
 └──────────────────────┘          │  credentials     │
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
| Metrics | `host_metrics` (CPU, memory, disk, network, load, paging, processes) | PostHog |
| Metrics | `docker_stats` per container, labelled with its swarm service and task | PostHog |
| Traces  | OTLP in on 4317/4318 — nothing produces them yet; the backend will | PostHog |

Every record carries `service.name`. For swarm containers that is the
swarm service (`srv-captain--camelotai`, `camelot-task-<uuid>`, …); for
containers outside swarm it is the container name; and node-level
`host_metrics`, which has no container at all, is attributed to the node
itself (`vnic-camelotai-01`). Without this metrics reach PostHog as
`unknown`, which is what a backend shows when `service.name` is absent.

Every log record additionally carries `host.name` (the swarm node),
`container.name`, `container.id` and `container.image.name`.

**Log severity is parsed for the Elixir app only.** The `container`
operator unwraps docker's JSON envelope but leaves the application's own
line alone, so without further parsing nothing sets severity and a
backend shows every record at its default level — in PostHog that is
`info`, which made a Postgrex disconnect and a failed migration look
identical to a 200.

Released builds log JSON (`logger_json`, configured for `:prod` in
`config/runtime.exs`), and the agent parses that first. This matters
beyond tidiness: docker gives the collector **one record per physical
line**, so a text-formatted stack trace arrives as several records with
only the first carrying `[error]` and the rest stranded at the default
level. JSON escapes the newlines, so the whole event stays one line and
one record.

A regex fallback handles anything that is not JSON — `IO.puts`,
early-boot SASL reports, `mix` output from `/app/bin/migrate`, and dev
builds, which keep the human-readable formatter.

The gateway then rewrites `severity_text` into the six canonical OTel
buckets, because Elixir says `warning` and `notice` while PostHog filters
on exact `warn` / `info`.

Lines from every other container — nginx, postgres, netdata — match
neither path, pass through untouched, and still arrive with no severity
(so PostHog shows them as `info`). Parsing those formats is a separate
job.

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

Two workflows, one per cluster, each gated on a
`DEPLOY_OTEL_COLLECTOR=true` variable in its own GitHub environment so it
no-ops until that cluster's CapRover apps exist:

| Workflow | Trigger | Environment | Cluster |
|---|---|---|---|
| `deploy-otel-collector.yml` | push to `develop` touching `otel-collector/**` | `test` | test.camelotai.tech |
| `deploy-otel-collector-production.yml` | push to `main` touching `otel-collector/**` | `production` | app.camelotai.tech |

Both build the images multi-arch and tag them with the commit sha.

The production workflow builds rather than reusing the image the develop
run produced, which is what `deploy-production.yml` does for the app.
That image is tagged with the develop commit sha, and main's second
parent is whatever develop pointed at when the release PR merged — not
necessarily the commit that last touched `otel-collector/`, so the tag is
frequently absent. These images are an upstream collector plus a `COPY`,
so rebuilding from the merged tree is cheap and keeps every tag
immutable.

**The setup below is per cluster.** Production needs its own CapRover
apps, its own app tokens in the `production` environment, its own node
label, and its own run of the Global bootstrap.

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
TaskTemplate:
    ContainerSpec:
      # Swarm templates this per task, so the container's hostname is the
      # node's name. host.name then resolves correctly even when the
      # docker detector times out at startup - which it did on the 1 GB
      # manager, leaving that agent reporting its own container id as a
      # host, and as a service, for a week.
      Hostname: "{{.Node.Hostname}}"
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

**Do not add a `Mode: Global: {}` block here — it cannot work.** CapRover
merges the override additively, so `Global` lands next to the generated
`Mode: Replicated` and docker rejects the spec with *"must specify only
one service mode"*. Saving it fails outright. The service is made Global
after the first deploy instead, with `bootstrap-global-agent.sh` below.

The mounts are all read-only except the offset directory. `/` at
`/hostfs` is what `host_metrics` measures — without it the scrapers
describe the collector's own container instead of the node.

Pre-create the offset directory on every node, so a missing path cannot
hold up a task:

```sh
sudo mkdir -p /var/lib/otelcol-agent
```

### 2. Make the agent Global (once, after the first deploy)

CapRover deploys the agent as an ordinary single-replica service, which
collects logs from one node only. A swarm service cannot be converted in
place — the daemon answers `service mode change is not allowed` — so it
has to be recreated. On a swarm manager:

```sh
./bootstrap-global-agent.sh otel-agent
```

It reuses the spec CapRover generated and changes only the mode, so every
label, network, mount and limit is preserved. It is idempotent, and safe
to re-run: it exits immediately if the service is already Global. Verify
with `docker service ls` — the agent should read `global   2/2`.

CapRover manages the service normally afterwards; its override merge is a
no-op against an already-Global spec. **Re-run this if the app is ever
deleted and recreated.**

### 3. App environment variables

On **`otel-gateway`**:

| Variable | Value |
|----------|-------|
| `POSTHOG_PROJECT_API_KEY` | project token, `phc_…` — *not* a personal API key |
| `POSTHOG_HOST` | `https://us.i.posthog.com` or `https://eu.i.posthog.com` |
| `DEPLOYMENT_ENV` | `test` (tags everything, so test and prod stay apart in one PostHog project) |

On **`otel-agent`**: nothing is required. `OTEL_GATEWAY_ENDPOINT`
defaults to `srv-captain--otel-gateway:4317`, and `OTEL_LOG_LEVEL`
to `warn`.

If you deploy the gateway under a different name via
`OTEL_GATEWAY_APP_NAME`, its CapRover service becomes
`srv-captain--<that name>` and the agent's default stops resolving — set
`OTEL_GATEWAY_ENDPOINT` on the agent app to match, or the agents export
into nothing.

### 4. GitHub configuration

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
  queue is in memory and bounded (1000 batches), so a PostHog outage
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
- **PostHog metrics are in private alpha.** Ingest is live — the EU
  endpoint returns 200 for this project — but the metrics *viewer* is
  enabled per team, so data can be accepted and still not be visible
  yet. Nothing else in the pipeline depends on it.
- **Metrics are sent with the temporality the receivers declare**
  (cumulative for `host_metrics` and `docker_stats`). PostHog reads the
  declared temporality rather than differencing, so if counters read as
  ever-growing totals in the viewer, insert a `cumulativetodelta`
  processor ahead of the exporter rather than changing the receivers.
- **A wrong `host.name` shows up as a wrong service.** Node metrics have
  no container, so `service.name` falls back to `host.name`. If that is
  wrong, an impostor service appears — a bare 12-hex-character name is a
  container short id, and means the agent on that node failed detection
  at startup. Restarting that agent re-runs detection; the
  `Hostname: "{{.Node.Hostname}}"` template above is what stops it
  recurring.
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
- **`Could not inspect updated container` is expected noise.** When a
  container exits, `docker_stats` and `docker_observer` can race to
  inspect it after it is gone and log an error apiece. Production churns
  `camelot-task-*` containers constantly, so this recurs. Nothing is
  dropped — the container simply stopped existing between the docker
  event and the inspect call.
- **Service names differ per cluster.** CapRover names newer apps bare
  (`otel-gateway` on test) and older ones with a prefix
  (`srv-captain--otel-gateway` on production). The agent's default
  `OTEL_GATEWAY_ENDPOINT` uses the prefixed form, which works on both:
  it is the real service name on production, and CapRover adds it as a
  network alias on test. Use `docker service ls` to see which form a
  cluster uses before writing scripts against a name.
- **Short-lived containers may be missed.** Discovery happens on a
  docker event, so a container that starts and exits within roughly a
  second can be gone before its receiver starts.
- The nodes are small and already OOM-prone, so `memory_limiter` is
  first in every pipeline and both services have swarm memory limits.
