# Docs site deployment (docs.camelotai.tech)

How the public documentation site is served and how to wire the CDN.

> This file lives flat under `docs/` (not in a category folder) and has no
> `published: true` front-matter, so it is **not** part of the public site.

## How it works

The docs site is **not** a separate app. It is served by the main Camelot
Phoenix app through a dedicated, unauthenticated router scope bound to the
`docs.` host:

- Content is compiled from `docs/<category>/**/*.md` at build time by
  `Camelot.Docs` (NimblePublisher). Only files with `published: true`
  front-matter are exposed. There is no database access and no runtime
  file I/O — pages are baked into the release.
- The `:docs` router pipeline is **cookie-free** (no session, no CSRF) and
  sets a long, CDN-friendly `Cache-Control` via
  `CamelotWeb.Plugs.DocsCacheControl`
  (`s-maxage=86400, stale-while-revalidate, stale-if-error`).
- A minimal root layout (`layouts/docs_root.html.heex`) is used — no
  LiveSocket / `app.js` — so pages are fully static and fast.

Because responses carry no cookies and long `s-maxage`, a CDN can cache
them at the edge and only hit the origin on a miss or revalidation.

## Adding / publishing a page

1. Put the markdown under a category folder, e.g.
   `docs/runners/my-guide.md`. Nesting to any depth is supported
   (`docs/runners/local/…`) — each folder becomes a nav category.
2. Add front-matter at the very top:

   ```
   %{
     title: "My guide",
     description: "One-line summary.",
     order: 1,
     published: true
   }
   ---
   # My guide
   ...
   ```

3. Relative `*.md` links between docs are rewritten to site slugs
   automatically (e.g. `cluster-runners.md` → `/runners/cluster-runners`).

Internal-only docs stay **flat** under `docs/` (like this file) and are
never globbed or published.

## Serving on CapRover directly (test): the `docs` proxy app

CapRover rejects `docs.<root-domain>` as a *custom domain* on the main app
("Custom domain cannot be subdomain of root domain"), so on the test cluster
the docs site is exposed via a small companion app named `docs` (an app
subdomain, which CapRover allows and auto-SSLs). It is a one-container
`nginx:alpine` reverse proxy that forwards to the main app with the `Host`
rewritten to a `docs.` value. Definition and setup live in
[`docs-proxy/`](../docs-proxy/README.md); CI deploys it via
`.github/workflows/deploy-docs-proxy.yml`.

This gives `https://docs.test.camelotai.tech`. Production instead fronts the
same app with CloudFront (below), so the proxy app is a test/staging
convenience, not the production path.

## One-time infrastructure (AWS)

DNS is in Route53; the origin is the CapRover-hosted app.

1. **ACM certificate** for `docs.camelotai.tech` in **`us-east-1`**
   (CloudFront requires certs in `us-east-1`). Validate via a Route53
   CNAME record.
2. **CloudFront distribution**:
   - Origin: the CapRover app host (the same origin that serves the main
     app), HTTPS-only, forwarding the `Host` header if the origin needs it.
   - Alternate domain name (CNAME): `docs.camelotai.tech`; attach the ACM
     cert.
   - Viewer protocol policy: redirect HTTP → HTTPS.
   - Cache behavior: **forward no cookies**, and respect the origin
     `Cache-Control` (use the "CachingOptimized" managed policy or a custom
     policy that honors origin headers). Do **not** forward the session
     cookie.
3. **Route53**: `A` and `AAAA` **ALIAS** records for `docs.camelotai.tech`
   pointing at the CloudFront distribution.

## CI cache invalidation

`.github/workflows/deploy-production.yml` runs a CloudFront invalidation
(`aws cloudfront create-invalidation --paths "/*"`) after each production
deploy. Content only changes on deploy, so this keeps the edge fresh
without shortening TTLs.

The step is a no-op until these are configured on the repo:

| Kind | Name | Value |
|------|------|-------|
| Variable | `DOCS_CF_DISTRIBUTION_ID` | CloudFront distribution id |
| Variable | `AWS_REGION` | optional, defaults to `us-east-1` |
| Secret | `AWS_ACCESS_KEY_ID` | IAM key with `cloudfront:CreateInvalidation` |
| Secret | `AWS_SECRET_ACCESS_KEY` | matching secret |

Scope the IAM policy to `cloudfront:CreateInvalidation` on that
distribution only.

## Local development

The `docs.` host resolves locally via `*.localhost`:

```
iex -S mix phx.server
open http://docs.localhost:4000/
```

Editing a markdown file triggers a recompile of `Camelot.Docs` (a
`live_reload` pattern for `docs/*.md` is configured in `config/dev.exs`).
