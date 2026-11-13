# 🏰 Camelot AI runner images

These images host the AI agent CLIs that 🏰 Camelot AI dispatches into one-shot
runner containers (one per session). They are *not* part of the 🏰 Camelot AI
release image — they ship separately and are referenced by name from
`Agent.runner_image` (the Agent CLI resource).

## Layering

```
base/                    debian + asdf + nodejs (default) + git + gh + tini + entrypoint.sh
                         + exec-wrapper.sh + fetch-attachments.sh
 ├─ claude/              + claude-code CLI
 ├─ codex/               + codex CLI
 ├─ kimi/                + kimi-code CLI (on its own node, see below)
 ├─ elixir/              FROM claude — adds elixir+erlang asdf plugins
 ├─ python/              FROM claude — adds python + uv
 └─ polyglot/            FROM base — everything, big and slow
```

## Entrypoint contract

`base/entrypoint.sh` runs on every container boot. It:

1. Materialises Swarm secrets at `/run/secrets/<kind>` into the right
   dotfile (`~/.claude/credentials.json`, `~/.config/gh/hosts.yml`, …).
2. Merges the image's baseline MCP set with `$PROJECT_MCP_CONFIG_JSON`,
   resolving `${credential:<kind>}` placeholders against
   `/run/secrets/<kind>`.
3. If `$BOOTSTRAP=1` — runs the command 🏰 Camelot AI supplied and exits.
4. Otherwise — clones `$REPO_URL` into `/workspace`, fetches the
   card's attachments (`/fetch-attachments.sh`, see below), runs
   `asdf install` (which picks up the repo's `.tool-versions`), then
   execs the command.

The cache volume mounted at `/home/agent` is treated as exactly that —
a cache. Every step above is idempotent; if the volume disappears, the
next session rebuilds it.

## Per-session exec contract

A task keeps **one long-lived container**; every session `docker exec`s
into it through `/exec-wrapper.sh`. The container's create-time env is
never updated, so the BEAM passes everything that can change between
sessions in the exec env (`Camelot.Runtime.Runner.SessionEnv`):
secrets, `PROJECT_MCP_CONFIG_JSON`, `CAMELOT_OUTPUT_SCHEMA_JSON` and
`ATTACHMENTS_JSON`. Exec-time values win over `/tmp/camelot.env`
(written at boot).

### Attachments

`/fetch-attachments.sh` downloads `$ATTACHMENTS_JSON`
(`[{"filename": …, "url": …}]`, links signed fresh every session) into
`/workspace/.camelot/attachments/`. It runs at boot **and** in the
exec-wrapper before every session, so a file uploaded to the card
after the container started reaches the next session. It:

- keeps only the basename of each filename and skips empty, `.`, `..`;
- skips files that already exist with a non-zero size;
- downloads to a temp file and `mv`s it into place
  (`curl -fsSL --retry 2 --max-time 120`);
- removes files no longer listed (deleted in the UI);
- adds `.camelot/attachments/` to `.git/info/exclude`, so an agent's
  `git add -A` can't commit the user's files;
- logs `[camelot] failed to fetch attachment <name>` to the session
  output and the container log, and never fails the session.

Containers built from an image older than this script keep the old
wrapper and only fetch at boot. On Swarm, services on a floating tag
(`:latest`) are rolled to the newest digest by the Reconciler's boot
sweep (`Swarm.TaskService.autoupdate_image/1`) on the next Camelot
restart. Pinned images, and Docker Engine containers, need recreating
by hand: `docker service rm camelot-task-<id>` (Swarm) or
`docker rm -f camelot-task-<id>` (Docker Engine); the next session
provisions a fresh one.

### Kimi credentials

A `kimi_api_key` secret is turned into `$KIMI_CODE_HOME/config.toml`
(default `~/.kimi-code`) by `kimi_configure`: it probes the Kimi Code
Console and Open Platform `/models` endpoints (global, then China) and
writes a provider for the first that accepts the key, plus a
`kimi-code/<id>` alias for every model listed. `KIMI_BASE_URL` skips
the probe for gateways. No-op in images without `kimi`.

## Kimi's node pin

`@moonshot-ai/kimi-code` declares `engines.node >= 22.19.0`, newer than
the base image's `NODEJS_VERSION`. `kimi/Dockerfile` installs its own
node (`KIMI_NODEJS_VERSION`) with asdf, installs the pinned CLI
(`KIMI_CODE_VERSION`) with it, and pins the `kimi` shebang to that
node — the base, and every other stack, keeps its baseline node. The
image also bakes `/opt/agent-cli/kimi/planning-agent.md`, the
read-only (`Read`/`Glob`/`Grep`) agent file planning runs load.

## Multi-arch

All images target both `linux/amd64` and `linux/arm64` (Ampere/Graviton
workers). The base Dockerfile reads `TARGETARCH` from buildx for the
gh CLI download; everything else (asdf, npm) is arch-agnostic.

## Building locally

Single-arch (matches your host — fast):

```sh
docker build -t camelot/runner-base:dev runner-images/base
docker build \
  --build-arg BASE_IMAGE=camelot/runner-base:dev \
  -t camelot/runner-claude:dev runner-images/claude
docker build \
  --build-arg CLAUDE_IMAGE=camelot/runner-claude:dev \
  -t camelot/runner-elixir:dev runner-images/elixir
```

Multi-arch (requires `docker buildx` + `qemu`):

```sh
docker buildx create --use --name camelot-builder
docker buildx build --platform linux/amd64,linux/arm64 \
  -t camelot/runner-base:dev --load runner-images/base
```

CI publishing happens via `.github/workflows/runner-images.yml`,
which pushes `ghcr.io/t0ha/camelot-runner-<stack>:<tag>` for both
architectures as a manifest list.
