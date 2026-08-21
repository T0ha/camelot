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

## One-time CapRover setup

1. **Create New App** named `docs` (no persistent data).
2. Generate an **App Token** (App → Deployment) and store it as the
   `DOCS_PROXY_APP_TOKEN` secret in the matching GitHub environment (`test`).
3. **Enable HTTPS** on the app's default `docs.<root>` domain.
4. Container HTTP Port is `80` (nginx default) — the CapRover default, so no
   change needed.
5. Set the GitHub variable `DEPLOY_DOCS_PROXY=true` to enable the CI workflow
   (it is opt-in so it stays green until the app + token exist).

Optionally override the defaults via the app's **Environmental Variables**:

| Var | Default | Meaning |
|-----|---------|---------|
| `DOCS_UPSTREAM` | `srv-captain--camelotai:4000` | main app service:port on the overlay |
| `DOCS_HOST` | `docs.test.camelotai.tech` | Host header sent upstream (must start with `docs.`) |

## Deploy

CI deploys this on pushes to `develop` that touch `docs-proxy/**` (see
`.github/workflows/deploy-docs-proxy.yml`), and it can be run manually
(workflow_dispatch).

Locally / by hand:

```sh
tar -czf /tmp/docs-proxy.tar.gz -C docs-proxy .
npx --yes caprover@2.3.1 deploy \
  --caproverUrl "$CAPROVER_SERVER" \
  --appToken "$DOCS_PROXY_APP_TOKEN" \
  --appName docs \
  --tarFile /tmp/docs-proxy.tar.gz
```

CapRover builds the image from `Dockerfile` server-side (just an nginx config
copy), so no registry push is needed.
