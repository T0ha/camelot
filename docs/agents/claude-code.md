%{
  title: "Setting up Claude Code",
  description: "Get an Anthropic API key or OAuth token, add it as a credential, and pick Claude Code for a task.",
  order: 1,
  published: true
}
---
# Setting up Claude Code

Claude Code is 🏰 Camelot AI's default Agent CLI, and the only one that's
**fully integrated and tested** today — start here unless you already
know you need [Codex](codex.md).

## 1. Get an API key

Either of these works:

- **Anthropic Console API key** — an `sk-ant-...` key from the
  [Anthropic Console](https://console.anthropic.com/).
- **Claude Code OAuth token** — if you're on a Claude subscription plan
  that supports the CLI, run `claude setup-token` locally and copy the
  resulting `sk-ant-oat...` token. This is billed against your
  subscription instead of pay-as-you-go API usage.

Camelot detects which one you pasted by its prefix, so either format
just works — see [how the key reaches the runner](#3-add-it-as-a-credential)
below.

## 2. Add it as a Credential

Go to `/profile` (any signed-in user, not admin-only) and add a
**Credential**:

- **Kind**: `claude_api_key`
- **Name**: anything memorable, e.g. `anthropic`
- **Value**: the key or token from step 1

Credentials are encrypted at rest and shipped securely to the runner
container that executes your tasks.

### Why either key format "just works"

The `claude_api_key` credential is mapped to an environment variable
before the runner starts:

- A plain `sk-ant-...` API key becomes `ANTHROPIC_API_KEY`.
- An `sk-ant-oat...` OAuth token becomes `CLAUDE_CODE_OAUTH_TOKEN`
  instead, with `ANTHROPIC_API_KEY` explicitly cleared so a stale key
  baked into the runner image can't take precedence.

You don't need to pick which env var to use — pasting either value into
the same `claude_api_key` credential routes it correctly.

## 3. Pick Claude Code on a task

When creating a task on the board, the **CLI Agent** dropdown lets you
choose which Agent CLI template runs it. Pick **Claude Code** — it's
pre-seeded, so there's nothing to configure per-project beyond having
the credential from step 2.

## 4. Admin: reviewing the template

Workspace admins can review or tune the Claude Code template at
`/agents` (admin-only). The seeded defaults — executable `claude`,
models `claude-opus-5` / `claude-sonnet-5` /
`claude-haiku-4-5-20251001`, default `claude-sonnet-5` — rarely need
touching.

## 5. Self-hosted: runner image

- **Docker / Swarm backends** run Claude Code inside the project's
  runner container. The prebuilt
  `ghcr.io/t0ha/camelot-runner-claude:latest` image already has it
  installed via `npm install -g @anthropic-ai/claude-code`.
- **Local dev (`LocalPort` backend)** runs the CLI directly on the host
  running Camelot instead of in a container, so `claude` must be
  installed and on `PATH` there too.

## Troubleshooting

- **401 / auth errors** — usually means the wrong credential kind was
  used (double-check it's `claude_api_key`, not `openai_api_key` or
  `codex_api_key`) or the key/token has expired.

---

See also: [Setting up Codex](codex.md) ·
[Get Started with Camelot Cloud](../cloud/get-started.md)
