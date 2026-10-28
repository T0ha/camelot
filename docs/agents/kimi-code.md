%{
  title: "Setting up Kimi Code",
  description: "Paste a Kimi API key, let Camelot detect its endpoint, and pick Kimi Code for a task.",
  order: 3,
  published: true
}
---
# Setting up Kimi Code

Kimi Code (`@moonshot-ai/kimi-code`) is the third Agent CLI on 🏰 Camelot
AI, alongside [Claude Code](claude-code.md) and [Codex](codex.md). Like
Codex it's newer than the Claude Code integration — **Claude Code is the
only Agent CLI that's fully integrated and tested** today. The
integration was verified against kimi-code **2.3.0**, which the runner
image pins.

## 1. Get an API key

Kimi Code has no `setup-token` equivalent: `kimi login` keeps its OAuth
tokens inside `~/.kimi-code` and they can't be extracted. Paste an API
key instead — either kind works:

| Source | Endpoint | China |
|---|---|---|
| Kimi Code Console (membership) | `https://api.kimi.ai/coding/v1` | `https://api.kimi.com/coding/v1` |
| Kimi Open Platform (pay-as-you-go) | `https://api.moonshot.ai/v1` | `https://api.moonshot.cn/v1` |

## 2. Add it as a Credential

Open the avatar menu and choose **API keys**, or go to
`/profile/api-keys`. Find the **Kimi API key — Kimi Code** row, paste
the key and click **Save**. There is one field for both key sources —
Camelot works out which endpoint the key belongs to.

Keys are encrypted at rest. The `kimi_api_key` credential reaches the
runner as `CAMELOT_SECRET_KIMI_API_KEY`, and the entrypoint turns it into
a Kimi config:

1. It calls `GET <endpoint>/models` with the key on each endpoint in
   the table above, in order (global Console, global Open Platform,
   China Console, China Open Platform). The first that answers `200`
   wins.
2. It writes `$KIMI_CODE_HOME/config.toml` (default
   `~/.kimi-code/config.toml`, mode `0600`) with one `camelot` provider
   for that endpoint and a `kimi-code/<id>` model alias for **every**
   id the listing returned. The default model is `k3` when listed,
   otherwise the first id.
3. If no endpoint accepts the key, it logs
   `kimi: no endpoint accepted the mounted key` and falls back to the
   CLI's env-only config, so the run fails with Kimi's own clear `401`.

### Gateways: `KIMI_BASE_URL`

To route through a gateway or proxy, set `KIMI_BASE_URL` (in the Kimi
template's env vars at `/agents`, or a project's env var override) to
its OpenAI-style base URL, e.g. `https://gateway.example/v1`. The probe
is skipped and that URL is used as-is.

## 3. Pick Kimi Code on a task

Pick **Kimi Code** in the **CLI Agent** dropdown. It's pre-seeded; the
board enables it once you hold a `kimi_api_key` credential.

How a run is shaped:

- every stage runs headless: `kimi -p "<prompt>" --output-format
  stream-json` — print mode is auto-permission already;
- **planning** adds `--agent-file /opt/agent-cli/kimi/planning-agent.md`,
  a read-only agent whose tool allowlist is `Read`, `Glob` and `Grep`.
  Kimi's `--plan` can't be combined with `-p`, so this is the read-only
  posture. **Trade-off:** the planner has no `Bash`, so it can't run
  `git log` or the tests while planning (Codex's read-only sandbox can);
- Kimi has no schema flag, so the planning system prompt asks for a bare
  JSON `{"decision", "plan", "questions"}` object as the final message.
  Camelot also accepts it inside a code fence or after a sentence, and
  falls back to question-phrase detection otherwise.

## 4. Models

Model values are **`kimi-code/<id>`** everywhere — the dropdown, the
pinned list and the `-m` flag. That is the alias form `kimi login`
writes into a developer's own config, so the same value works on
`LocalPort` and in containers. A model the config doesn't know fails
fast with `Model "kimi-code/x" is not configured in config.toml`.

The **Model** dropdown is resolved live per user, with the probe walking
the same four endpoints in order: the first that answers wins, a `401`
or network error moves on to the next. Ids are filtered to coding
models (`^(k\d|kimi)`) and prefixed with `kimi-code/`. When discovery
can't answer, the dropdown falls back to the pinned list:
`kimi-code/k3`, `kimi-code/k3.1-pro`, `kimi-code/k3.1-pro-highspeed`,
`kimi-code/k3-256k`, `kimi-code/kimi-for-coding`,
`kimi-code/kimi-for-coding-highspeed`.

`default_model` is left blank: the config's own default applies.

## 5. Self-hosted: runner image

- **Docker / Swarm backends** use
  `ghcr.io/t0ha/camelot-runner-kimi:latest`. Kimi Code needs node
  `>= 22.19.0`, newer than the base image's, so the kimi image installs
  its own node and pins the `kimi` shebang to it; other stacks are
  unaffected.
- **Local dev (`LocalPort` backend)** runs the host's `kimi` with the
  developer's own `kimi login` and `~/.kimi-code`. `LocalPort` doesn't
  mount secrets, so the pasted key isn't used there: log in yourself.
  `kimi login` creates the same `kimi-code/*` aliases the dropdown
  offers.

## Usage limits

Kimi's stream carries no usage, cost or rate-limit events, so Kimi runs
record no usage snapshots. Usage limits are still detected from the
CLI's error line: `provider.rate_limit` (the CLI has already retried
it) or a quota-exhausted message pauses the task and the credential
like the other agents. `provider.auth_error` is a bad key, not a limit,
and errors normally.

## Troubleshooting

- **`kimi: no endpoint accepted the mounted key`** in the runner log —
  the key was rejected everywhere: re-paste it, or set `KIMI_BASE_URL`
  if you use a gateway.
- **`Model "kimi-code/x" is not configured in config.toml`** — the
  task's model isn't one your key's endpoint listed; pick another from
  the dropdown.

---

See also: [Setting up Claude Code](claude-code.md) ·
[Setting up Codex](codex.md)
