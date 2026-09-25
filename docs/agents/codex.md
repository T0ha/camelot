%{
  title: "Setting up Codex",
  description: "Get an OpenAI API key, add it as a credential, and pick Codex for a task.",
  order: 2,
  published: true
}
---
# Setting up Codex

Codex is a supported Agent CLI on 🏰 Camelot AI, alongside
[Claude Code](claude-code.md). It's newer than the Claude Code integration
— **Claude Code is the only Agent CLI that's fully integrated and
tested** today — and its model list isn't pre-filled by default (see
[step 4](#4-admin-fill-in-the-model-list) below).

## 1. Get an API key

Grab an API key from the [OpenAI platform](https://platform.openai.com/).

## 2. Add it as a Credential

Go to `/profile` (any signed-in user, not admin-only) and add a
**Credential**:

- **Kind**: `codex_api_key` (or `openai_api_key` — both map to the same
  env var)
- **Name**: anything memorable, e.g. `openai`
- **Value**: the API key from step 1

Credentials are encrypted at rest and shipped securely to the runner
container that executes your tasks. Both `codex_api_key` and
`openai_api_key` are mapped to `OPENAI_API_KEY` before the runner
starts, so either kind works.

## 3. Pick Codex on a task

When creating a task on the board, the **CLI Agent** dropdown lets you
choose which Agent CLI template runs it. Pick **Codex** — it's
pre-seeded, so there's nothing to configure per-project beyond having
the credential from step 2.

## 4. Admin: fill in the model list

Workspace admins can review the Codex template at `/agents`
(admin-only). Unlike Claude Code, the seed script deliberately leaves
`available_models` and `default_model` **blank** — the Codex CLI's
current `--model` values weren't confirmed at seed time. Until an admin
fills these in (verified against the Codex CLI's own docs), no model
switching is offered for Codex tasks.

## 5. Self-hosted: runner image

- **Docker / Swarm backends** run Codex inside the project's runner
  container. The prebuilt
  `ghcr.io/t0ha/camelot-runner-codex:latest` image already has it
  installed via `npm install -g @openai/codex`.
- **Local dev (`LocalPort` backend)** runs the CLI directly on the host
  running Camelot instead of in a container, so `codex` must be
  installed and on `PATH` there too.

## Troubleshooting

- **401 / auth errors** — usually means the wrong credential kind was
  used, or the key has expired.
- **No models shown when creating a task** — the admin hasn't filled in
  `available_models` for the Codex template yet (see
  [step 4](#4-admin-fill-in-the-model-list)).

---

See also: [Setting up Claude Code](claude-code.md) ·
[Get Started with Camelot Cloud](../cloud/get-started.md)
