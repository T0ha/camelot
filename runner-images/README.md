# Camelot runner images

These images host the AI agent CLIs that Camelot dispatches into one-shot
runner containers (one per session). They are *not* part of the Camelot
release image — they ship separately and are referenced by name from
`AgentTemplate.runner_image`.

## Layering

```
base/                    debian + asdf + nodejs (default) + git + gh + tini + entrypoint.sh
 ├─ claude/              + claude-code CLI
 ├─ codex/               + codex CLI
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
3. If `$BOOTSTRAP=1` — runs the command Camelot supplied and exits.
4. Otherwise — clones `$REPO_URL` into `/workspace`, runs `asdf install`
   (which picks up the repo's `.tool-versions`), then execs the
   command.

The cache volume mounted at `/home/agent` is treated as exactly that —
a cache. Every step above is idempotent; if the volume disappears, the
next session rebuilds it.

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
