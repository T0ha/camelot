# GitHub App integration

Camelot authenticates to GitHub two ways:

1. **GitHub App** (recommended) — per-project, used for server-side PR/issue
   polling (`Camelot.Github.Client`) and for runner git/`gh` auth once a
   project is linked to an installation. Opt-in per deployment.
2. **SSH key** — generated automatically for every user, shown on their
   profile page, and always injected into runner containers. Works
   independently of the GitHub App and needs no configuration.

Pasted personal access tokens / OAuth tokens are **not** supported. If an
`AgentTemplate`'s MCP config references `${credential:github_pat}`, update it
to `${credential:github_app_token}` (only meaningful for projects linked to a
GitHub App installation).

## 1. Register the App

On github.com, create a new GitHub App (either a personal or org App) with:

- **Permissions**: Repository — Contents (read/write), Pull requests
  (read/write), Issues (read/write), Checks (read), Metadata (read).
- **Webhook events**: `installation`, `installation_repositories`.
- **Setup URL**: `https://<your-camelot-host>/github/setup`
- **Webhook URL**: `https://<your-camelot-host>/github/webhooks`

**Checks (read) is required** for PR CI-status polling — Camelot reads
`commits/{sha}/check-runs` to auto-fix a task when CI fails. Without it that
endpoint returns `403 "Resource not accessible by integration"`. Camelot now
degrades gracefully (CI-failure detection is skipped; merge-conflict, review,
and comment handling keep working), so it is safe to omit, but CI-failure
auto-fix stays off until the permission is granted.

> **Changing permissions on an already-installed App does not take effect
> immediately.** GitHub raises a *pending permission request* that the
> account/org owner must approve (Settings → Installed GitHub Apps → the App →
> "Review request"), and Camelot caches installation access tokens for up to
> ~1h — so a newly granted permission can take up to an hour to apply unless
> the app is restarted.

Both URLs are also shown on `/admin/settings` once the App is configured
(see below), so you can copy them from there.

After creating the App, generate a private key (downloads a `.pem` file) and
note the App ID, Client ID, Client secret, and the webhook secret you set.

## 2. Configure the deployment

GitHub App credentials are deployment config, not something set through the
UI — like `ENCRYPTION_KEY` or `SECRET_KEY_BASE`, they're set once by whoever
registers the App and read via `config/runtime.exs`. Six env vars:

| Variable | Description |
|----------|-------------|
| `GITHUB_APP_ID` | Numeric App ID |
| `GITHUB_APP_SLUG` | App's URL slug (from `https://github.com/apps/<slug>`) |
| `GITHUB_APP_CLIENT_ID` | Client ID |
| `GITHUB_APP_CLIENT_SECRET` | Client secret |
| `GITHUB_APP_PRIVATE_KEY_B64` | The downloaded `.pem`, **base64-encoded** |
| `GITHUB_APP_WEBHOOK_SECRET` | Webhook secret you set when registering the App |

`GITHUB_APP_PRIVATE_KEY_B64` must be base64-encoded (not the raw multi-line
PEM) to avoid newline-escaping problems in most env-var/secret-store tooling:

```sh
base64 -w0 < downloaded-private-key.pem
```

All six are optional — if any is missing, the integration is treated as not
configured (`Camelot.Github.AppConfig.configured?/0` returns `false`), and
Camelot falls back to unauthenticated GitHub API calls / SSH-only runner
auth, exactly as if the App didn't exist.

## 3. Link a project

Once configured, a project's page shows a "Connect GitHub App" button that
sends you to GitHub's installation flow; after installing (or updating an
existing installation) on the target repo(s), GitHub redirects back to
`/github/setup`, which links the installation to that project.

A project can be disconnected at any time from the same panel — runners fall
back to the user's SSH key (if any) with no other change needed.

## 4. Known limitation

Installation access tokens last about an hour. A task whose run outlives
that isn't refreshed mid-run today — the next dispatch mints a fresh token.
A git-credential-helper hitting an internal Camelot endpoint is the natural
follow-up if long-running tasks become common, but isn't implemented yet.
