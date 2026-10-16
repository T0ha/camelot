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
tested** today.

## 1. Get an API key

Grab an API key from the [OpenAI platform](https://platform.openai.com/).
Codex on Camelot runs inside a runner container with no browser, so a
ChatGPT-account login isn't an option — an API key is the only supported
path.

## 2. Add it as a Credential

Go to `/profile` (any signed-in user, not admin-only) and add a
**Credential**:

- **Kind**: `openai_api_key`
- **Name**: anything memorable, e.g. `openai`
- **Value**: the API key from step 1

Credentials are encrypted at rest and shipped securely to the runner
container that executes your tasks. The `openai_api_key` credential is
mapped to `OPENAI_API_KEY` before the runner starts.

## 3. Pick Codex on a task

When creating a task on the board, the **CLI Agent** dropdown lets you
choose which Agent CLI template runs it. Pick **Codex** — it's
pre-seeded, so there's nothing to configure per-project beyond having
the credential from step 2.

## 4. Model discovery

The **Model** dropdown is resolved live, per user: Camelot calls
`GET https://api.openai.com/v1/models` with the credential that will
actually run the task and offers what comes back. No tokens are
billed, and the listing is the account catalog — so it is filtered down
to the model families the CLI's `--model` flag accepts (`gpt-*`,
`o*`, `codex-*`), which is why `whisper-1` never appears in the
dropdown.

Whose key is used depends on where you are:

- the **New Task** modal uses yours — you become the task's creator;
- an existing **task page** uses the *creator's*, even when somebody
  else is looking at it, because the runner mounts the creator's key.

Each answer is cached for an hour (a minute, if the call failed), keyed
to the user and to the key itself, so rotating or deleting the
credential takes effect immediately.

When discovery can't answer — no key stored, the probe disabled, OpenAI
unreachable or refusing the key — the dropdown falls back to the
template's pinned `available_models`. Nothing about the page changes;
you just see the offline list.

## 5. Admin: reviewing the model list

Workspace admins can review or tune the Codex template at `/agents`
(admin-only). Two fields drive the dropdown:

- **Model discovery probe** — the JSON above (URL, auth style,
  credential kind, `include` filter). Clearing it to `{}` turns
  discovery off for this template. An edit takes effect on the next
  render.
- **Available models** — the offline fallback described above. The
  seeded `gpt-5.6-terra` / `gpt-5.6-luna` / `gpt-5.5` were established
  by invoking each candidate against the Codex CLI and keeping the ones
  that completed, which scopes them to the account they were verified
  under. Nothing ever rewrites this column automatically: the per-row
  **Check models** action shows what your own key is entitled to, and
  **Pin these** copies it here only when you ask.

`default_model` is left blank on purpose: with no `--model` flag the
CLI picks its own default.

## 6. Self-hosted: runner image

- **Docker / Swarm backends** run Codex inside the project's runner
  container. The prebuilt
  `ghcr.io/t0ha/camelot-runner-codex:latest` image already has it
  installed via `npm install -g @openai/codex`. This is also the
  posture the seeded template assumes — its permission args tell Codex
  to bypass its own approval prompts because the container is already
  the sandbox.
- **Local dev (`LocalPort` backend)** runs the CLI directly on the host
  running Camelot instead of in a container, so `codex` must be
  installed and on `PATH` there too. Because the seeded template's
  permission args assume a throwaway container, running it under
  `LocalPort` gives Codex unsandboxed access to whatever checkout it's
  pointed at — tighten `permission_args_by_stage` at `/agents` (or
  per-project) before doing that.

## Troubleshooting

- **401 / auth errors** — usually means the wrong credential kind was
  used (double-check it's `openai_api_key`), or the key has expired.
- **Model rejected with a 400** — the task's model isn't accepted by
  your account; see [step 4](#4-admin-reviewing-the-model-list) and
  adjust `available_models` at `/agents`.
- **Task pauses instead of erroring** — Camelot recognizes a provider
  usage-limit rejection and pauses the task (and any other queued task
  on the same credential) instead of retrying or erroring. It resumes
  automatically once the limit resets, or via "Resume now" on the task.

---

See also: [Setting up Claude Code](claude-code.md) ·
[Get Started with Camelot Cloud](../cloud/get-started.md)
