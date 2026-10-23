%{
  title: "Setting up Antigravity",
  description: "Get a Gemini API key, add it as a credential, and pick Google Antigravity CLI for a task.",
  order: 3,
  published: true
}
---
# Setting up Antigravity

The Google Antigravity CLI (`agy`) is a supported Agent CLI on
🏰 Camelot AI, alongside [Claude Code](claude-code.md) and
[Codex](codex.md). It's the newest integration — **Claude Code is the
only Agent CLI that's fully integrated and tested** today.

## 1. Get an API key

Create a Gemini API key in [Google AI Studio](https://aistudio.google.com/apikey).
Antigravity on Camelot runs inside a runner container with no browser,
so a Google-account login isn't an option — an API key is the only
supported path.

## 2. Add it as a Credential

Open the avatar menu (top right) and choose **API keys** (any
signed-in user, not admin-only), or go to `/profile/api-keys`. Find the
**Gemini API key — Antigravity** row, paste the API key from step 1 and
click **Save**. Saving again replaces it; **Remove** deletes it.

Keys are encrypted at rest and shipped securely to the runner
container that executes your tasks. The `gemini_api_key` credential is
mapped to both `GEMINI_API_KEY` and `GOOGLE_API_KEY` before the runner
starts — `agy` reads either.

## 3. Pick Antigravity on a task

When creating a task on the board, the **CLI Agent** dropdown lets you
choose which Agent CLI template runs it. Pick **Antigravity** — it's
pre-seeded, so there's nothing to configure per-project beyond having
the credential from step 2.

Each stage runs `agy` headless with `--output-format stream-json`, the
prompt passed to `-p`, and `--dangerously-skip-permissions` (there is
no TTY to approve tool requests at):

| Stage | Mode | Extra |
|-------|------|-------|
| planning | `--mode plan` | `--json-schema` — the plan-or-question contract from [Planning output contract](../planning-output-contract.md) |
| executing | `--mode accept-edits` | |
| pr | `--mode accept-edits` | |

`agy` has no `--append-system-prompt` flag, so each stage's system
prompt is prepended to the prompt itself. The text lives in the
`agy_planning_system_prompt`, `agy_execution_system_prompt` and
`agy_pr_system_prompt` templates at `/prompts`, where it can be edited
per project or per user.

## 4. Models

The template is pinned to `gemini-3.8-flash-high` by default, and the
offline list offers:

- `gemini-3.8-flash-high`, `gemini-3.8-flash-medium`, `gemini-3.8-flash-low`
- `claude-sonnet-4-6`, `claude-opus-4-6-thinking`
- `gpt-oss-120b-medium`

The **Model** dropdown is also resolved live, per user: Camelot calls
`GET https://generativelanguage.googleapis.com/v1beta/models` with the
credential that will actually run the task (on the `x-goog-api-key`
header), strips the `models/` prefix Google puts on each id, and keeps
the `gemini-*` family. A successful answer supersedes the pinned list;
when discovery can't answer — no key stored, the probe disabled, Google
unreachable or refusing the key — the dropdown falls back to the pinned
list. Answers are cached for an hour (a minute, if the call failed),
keyed to the user and the key itself.

Google's listing is the Gemini API catalog, not `agy`'s own model menu,
so the non-Gemini models `agy` offers (Claude, GPT-OSS) only appear
through the pinned list. To always offer the pinned list instead, clear
the template's **Model discovery probe** to `{}` at `/agents`.

## 5. Admin: tuning the template

Workspace admins can review or tune the Antigravity template at
`/agents` (admin-only):

- **Model discovery probe** — the JSON described above. `auth` is
  `google`; `strip_prefix` trims `models/`; `include` filters ids.
- **Available models** / **Default model** — the pinned list and the
  model used when a task doesn't pick one. The per-row **Check models**
  action shows what your own key is entitled to, and **Pin these**
  copies it here only when you ask.
- **Permission args by stage** — the per-stage flags in the table
  above.

## 6. Self-hosted: runner image

- **Docker / Swarm backends** run `agy` inside the project's runner
  container. The `ghcr.io/t0ha/camelot-runner-agy:latest` image is
  built from `runner-images/agy/Dockerfile`, which installs the CLI
  with Google's install script
  (`curl -fsSL https://antigravity.google/cli/install.sh | bash`) and
  moves the binary into `/opt/agent-cli/bin`. Build it locally with:

  ```sh
  docker build \
    --build-arg BASE_IMAGE=ghcr.io/t0ha/camelot-runner-base:latest \
    -t ghcr.io/t0ha/camelot-runner-agy:latest runner-images/agy
  ```

- **Local dev (`LocalPort` backend)** runs the CLI directly on the host
  running Camelot, so `agy` must be installed and on `PATH` there too.
  Because the seeded template skips `agy`'s permission prompts on the
  assumption that a throwaway container is the sandbox, running it
  under `LocalPort` gives it unprompted access to whatever checkout
  it's pointed at — tighten `permission_args_by_stage` at `/agents`
  (or per-project) before doing that.

## Troubleshooting

- **`antigravity error: …` on the task** — the run's closing result
  event reported a status other than `SUCCESS`; the message after the
  colon is what `agy` returned.
- **401 / 403 from the model probe or the CLI** — check the key is
  stored as `gemini_api_key` and is still valid in AI Studio.
- **Model rejected** — the task's model isn't available to your key;
  pick another, or adjust **Available models** at `/agents`.

---

See also: [Setting up Claude Code](claude-code.md) ·
[Setting up Codex](codex.md) ·
[Get Started with Camelot Cloud](../cloud/get-started.md)
