%{
  title: "GitHub App",
  description: "Authenticate 🏰 Camelot AI to GitHub for PRs, issues and webhooks.",
  order: 4,
  published: true
}
---
# GitHub App integration

🏰 Camelot AI authenticates to GitHub two ways:

1. **GitHub App** (recommended) — connected per user, used for server-side
   PR/issue polling (`Camelot.Github.Client`) and for runner git/`gh` auth
   once a project's repo is covered by one of the connected installations.
   Opt-in per deployment.
2. **SSH key** — generated automatically for every user, shown on their
   profile page, and always injected into runner containers. Works
   independently of the GitHub App and needs no configuration.

The same App registration also powers **"Log in with GitHub"** on
`/sign-in`, which signs a user in *and* connects their installation in one
round trip — see [Log in with GitHub](#4-log-in-with-github).

Pasted personal access tokens / OAuth tokens are **not** supported. If an
`Agent`'s (Agent CLI's) MCP config references `${credential:github_pat}`,
update it to `${credential:github_app_token}` (only meaningful for projects
linked to a GitHub App installation).

## 1. Register the App

On github.com, create a new GitHub App (either a personal or org App) with:

- **Permissions**: Repository — Contents (read/write), Pull requests
  (read/write), Issues (read/write), Checks (read), Metadata (read).
- **Permissions**: Account — Email addresses (read-only).
- **Webhook events**: `installation`, `installation_repositories`.
- **Setup URL**: `https://<your-camelot-host>/github/setup`
- **Webhook URL**: `https://<your-camelot-host>/github/webhooks`
- **Callback URL**: `https://<your-camelot-host>/auth/user/github/callback`
- **Request user authorization (OAuth) during installation**: leave
  **unchecked**.

**Account → Email addresses (read-only) is required** for "Log in with
GitHub". Without it GitHub returns no address, and 🏰 Camelot AI refuses the
sign-in rather than guessing — it only ever trusts an address GitHub reports
as *verified*.

> **"Request user authorization (OAuth) during installation" must stay off.**
> With it on, GitHub redirects post-install to the *Callback URL* instead of
> the *Setup URL*, so the "Connect GitHub App" link on `/profile` lands on
> `/auth/user/github/callback` carrying a `state` the app never issued, and
> the sign-in fails with a CSRF error.

**Checks (read) is required** for PR CI-status polling — 🏰 Camelot AI reads
`commits/{sha}/check-runs` to auto-fix a task when CI fails. Without it that
endpoint returns `403 "Resource not accessible by integration"`. 🏰 Camelot AI now
degrades gracefully (CI-failure detection is skipped; merge-conflict, review,
and comment handling keep working), so it is safe to omit, but CI-failure
auto-fix stays off until the permission is granted.

> **Changing permissions on an already-installed App does not take effect
> immediately.** GitHub raises a *pending permission request* that the
> account/org owner must approve (Settings → Installed GitHub Apps → the App →
> "Review request"), and 🏰 Camelot AI caches installation access tokens for up to
> ~1h — so a newly granted permission can take up to an hour to apply unless
> the app is restarted.

All three URLs are also shown on `/admin/settings` once the App is
configured (see below), so you can copy them from there.

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
🏰 Camelot AI falls back to unauthenticated GitHub API calls / SSH-only runner
auth, exactly as if the App didn't exist. "Log in with GitHub" is switched
off the same way: the button still renders, but pressing it explains the
instance isn't configured and sends you back to the magic-link form.

`AppConfig` is deliberately all-or-nothing across all six variables, so
GitHub *login* also needs the webhook secret set. Since the point of the
feature is to install the App during login, the coupling is intentional.

## 3. Connect an installation

Once configured, `/profile` shows a "Connect GitHub App" button that sends
you to GitHub's installation flow; after installing (or updating an existing
installation) on the target repo(s), GitHub redirects back to
`/github/setup`, which links the installation to your user. Projects then
resolve their repo through whichever of your installations covers it.

An installation can be disconnected at any time from the same panel —
runners fall back to the user's SSH key (if any) with no other change
needed.

> **Installations are single-owner.** `Camelot.Github.Installation` belongs
> to at most one user, so for a shared *org* installation the first Camelot
> user to connect it claims it; teammates see nothing and are asked to
> install again. This is a pre-existing limitation, but GitHub login
> surfaces it much more often.

## 4. Log in with GitHub

With the App configured, `/sign-in` offers **Sign in with Github** next to
the magic-link form. Pressing it runs the whole connection in one round
trip:

1. GitHub's authorize screen appears — for a user who hasn't installed the
   App yet it usually offers *Install & Authorize* inline.
2. 🏰 Camelot AI reads the account's **verified primary email** and numeric
   user id, signs the user in, and links every installation the user can see
   (`GET /user/installations`) to their account.
3. If they still have no installation, they're sent to the App's install
   page once. Declining is remembered for that session, so they aren't
   bounced to github.com on every login.

The result is that a brand-new user lands on the board already connected —
there is **no separate step on `/profile`**.

### Which account a GitHub login belongs to

GitHub's numeric user id is the anchor; email is only a fallback:

| GitHub account | Behaviour |
|----------------|-----------|
| Known id, unchanged email | Signs in. |
| Known id, **different verified email** | Signs in as the *same* user, email untouched, then asks whether to adopt the new address. |
| Unknown id, email matches a user | Signs in as that user and records the GitHub id (an existing magic-link user's first GitHub login). |
| Neither matches | Registers a new user, subject to `REGISTRATION_ENABLED`. |

Matching an existing account never changes it: role, swarm node pin,
notification preferences and email are all left as they are.

### When the GitHub email changes

Because the account is recognised by id, changing your primary email on
GitHub no longer creates a second Camelot user. Instead the next login shows
a short page with both addresses and two buttons:

- **Update my email** — moves the Camelot account to the new address. Magic
  sign-in links go there from then on.
- **Keep current** — records the decision, so that same address is never
  offered again. Changing the GitHub email *again* prompts again.

Nothing is changed without pressing one of them. If the new address already
belongs to a different Camelot user the prompt is skipped entirely —
accounts are never merged.

### Invite-only instances

`REGISTRATION_ENABLED=false` applies to GitHub login as well: a GitHub
account that matches no existing user gets the same invite-only message the
magic-link form shows. Existing users keep signing in either way.

## 5. Known limitation

Installation access tokens last about an hour. A task whose run outlives
that isn't refreshed mid-run today — the next dispatch mints a fresh token.
A git-credential-helper hitting an internal 🏰 Camelot AI endpoint is the natural
follow-up if long-running tasks become common, but isn't implemented yet.

