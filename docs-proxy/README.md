# docs-proxy

A tiny `nginx:alpine` reverse proxy deployed as a **separate CapRover app**
named `docs`, so the Camelot documentation site is reachable at
`docs.<caprover-root-domain>` (e.g. `docs.test.camelotai.tech`).

## Why this exists

The docs site is served by the **main** Camelot app, gated to hosts starting
with `docs.` (see `CamelotWeb.Router`). On CapRover you cannot attach
`docs.<root>` as a *custom domain* to the main app — CapRover reserves
subdomains of its own root domain and rejects them
("Custom domain cannot be subdomain of root domain"). But CapRover **does**
give an app named `docs` the subdomain `docs.<root>` automatically, with
auto-SSL. This proxy is that app: it forwards to the main app with the `Host`
header rewritten to a `docs.` value so Phoenix serves the docs.

```
browser → docs.<root> (CapRover edge, TLS)
        → srv-captain--docs (this proxy)
        → ${DOCS_UPSTREAM}  with  Host: ${DOCS_HOST}
        → Phoenix docs host-route
```

## Image build model

The image is **built and pushed by CI** (GitHub Actions →
`ghcr.io/t0ha/camelotai-docs-proxy`), and CapRover only **pulls it by image
name**. We do not let CapRover build from source: on this cluster CapRover's
source-build push to the registry is denied ("token does not match expected
scopes"), because the registry credentials are read-only for pulling the main
app. Building in CI (as the main app already does) sidesteps that entirely.

## One-time CapRover setup

1. **Create New App** named `docs` (no persistent data).
2. Generate an **App Token** (App → Deployment) and store it as the
   `DOCS_PROXY_APP_TOKEN` secret in the matching GitHub environment (`test`).
3. **Enable HTTPS** on the app's default `docs.<root>` domain (do this
   *before* toggling "Force HTTPS", otherwise CapRover errors with
   "Cannot force SSL without at least one SSL-enabled domain").
4. Container HTTP Port is `80` (nginx default) — the CapRover default, so no
   change needed.
5. Set the GitHub variable `DEPLOY_DOCS_PROXY=true` (in the `test`
   environment) to enable the CI workflow (it is opt-in so it stays green
   until the app + token exist).

Optionally override the defaults via the app's **Environmental Variables**:

| Var | Default | Meaning |
|-----|---------|---------|
| `DOCS_UPSTREAM` | `srv-captain--camelotai:4000` | main app service:port on the overlay |
| `DOCS_HOST` | `docs.test.camelotai.tech` | Host header sent upstream (must start with `docs.`) |

## Deploy

CI deploys this on pushes to `develop` that touch `docs-proxy/**` (see
`.github/workflows/deploy-docs-proxy.yml`), and it can be run manually
(workflow_dispatch).

To deploy by hand, build & push the image, then point CapRover at it:

```sh
IMAGE=ghcr.io/t0ha/camelotai-docs-proxy:manual
docker buildx build --platform linux/amd64,linux/arm64 \
  -t "$IMAGE" --push docs-proxy

npx --yes caprover@2.3.1 deploy \
  --caproverUrl "$CAPROVER_SERVER" \
  --appToken "$DOCS_PROXY_APP_TOKEN" \
  --appName docs \
  --imageName "$IMAGE"
```
