# Get Started

This is a task-by-task walkthrough of Camelot's core loop: sign in, wire up
a project and an agent, create a task, and follow it all the way to a
merged pull request.

## Prerequisites

Get the app running first — see the README's
[Installation](../README.md#installation) section for `mix setup` and
starting the server. Everything below assumes it's up at
`localhost:4000`.

## 1. Sign in

Camelot uses passwordless magic-link auth — there's no signup form and no
password to set.

**Bootstrapping the first account.** On a fresh install nobody can sign in
yet, so create the first admin from the command line:

```sh
mix camelot.create_user me@example.com
```

This defaults to `--role admin`. Every account after this one can either
be created the same way (`--role user`) or invited by an admin from the
UI (see [Invite your team](#2-invite-your-team) below).

**Signing in.** Go to `/sign-in` and enter your email. Camelot emails you a
magic link that's valid for 10 minutes. In development, mail isn't
actually sent — open `/dev/mailbox` to read it and click the link. On
first sign-in, Camelot also generates an SSH keypair for you automatically
(more on that in [Set up your profile](#3-set-up-your-profile)).

If `REGISTRATION_ENABLED=false` (the default for a hosted/cloud
deployment), only emails an admin has already added can request a magic
link — everyone else needs to be invited first.

## 2. Invite your team

Admins can add teammates without touching the command line: go to
`/admin/users`, fill in **Email** and **Role** under "Add user", and
submit. The new user gets an invitation email and signs in via the same
magic-link flow above.

## 3. Set up your profile

Visit `/profile` to finish your personal setup:

- **SSH key** — Camelot already generated an Ed25519 keypair for you on
  first sign-in. Copy the public key shown here and add it to
  [github.com/settings/keys](https://github.com/settings/keys) (or any
  other git host) so runners can clone your private repos. If you ever
  need to replace it, "Generate new key" rotates it — remember to update
  it everywhere the old key was installed.
- **Credentials** — add any API keys or tokens your agents will need:
  a Claude API key, an OpenAI/Codex API key, a GitHub personal access
  token, or a GitHub OAuth token. Pick a **Kind**, give it a **Name**, and
  paste the **Value**. These are encrypted at rest and shipped securely to
  runner containers.

## 4. Create a project

Go to `/projects/new`. Only **Name** is required — Camelot derives a
local path under `~/projects/<slug>` if you don't pick one with the
**Path** folder picker. Optional fields:

- **Description**
- **GitHub URL** / **GitHub Owner** / **GitHub Repo** — set these so
  Camelot can open PRs and poll CI status for this project. If your local
  repo already has a GitHub remote, these are auto-detected.
- **Runner Image Override** — only needed if this project requires a
  non-default runner image.

Click **Save**.

## 5. Add an agent

Go to `/agents/new` and fill in:

- **Name** — anything memorable
- **Template** — the CLI tool this agent runs (e.g. Claude Code or Codex);
  admins manage the available templates at `/agent-templates`
- **Project** — the project this agent works on
- **Max retries** — how many times it retries a failed run

Click **Create Agent**. An agent is just a worker tied to one project — a
project can have several.

## 6. (Optional) Customize prompts

At `/prompts` you can define system/user prompt templates, scoped
globally or to a specific project, with `{{title}}`, `{{description}}`,
and `{{plan}}` placeholders. Skip this to start — Camelot ships with
sensible defaults.

## 7. Create your first task

On the board (`/`), click **New Task** and fill in **Title**,
**Description**, **Project**, and **Priority**, then **Create Task**.
You don't pick an agent here — Camelot dispatches the task to an
available agent for that project automatically.

## 8. Review and approve the plan

Once an agent picks up the task, it moves to `planning` and the agent
writes a plan before touching any code. Open the task (`/tasks/:id`) to
read it under **Plan**, then either:

- **Approve Plan** — the agent starts executing, or
- **Request Changes** — send it back with feedback

Nothing gets implemented until you approve.

## 9. Watch it execute

After approval the task moves to `executing`, and the task page streams
the agent's live output in real time under **Live output** — assistant
messages, tool calls, and the final result, as they happen.

## 10. Review and merge the PR

When the agent finishes, it opens a pull request and the task moves to
`pr`. The task page shows a **PR #&lt;number&gt;** link straight to
GitHub — review the diff there as you normally would.

Camelot also polls GitHub for this PR every 2 minutes in the background:

- CI failures, requested changes, or new review comments automatically
  kick the task back to the agent, which pushes fixes without you having
  to ask.
- Once the PR is merged, the task moves to `done` on its own.

You can also act manually from the task page at any point: **Approve
PR** marks the task done immediately, or **Request Changes** sends it
back to the agent.

Merging the PR (or clicking **Approve PR**) is the finish line — that's
your first task shipped end-to-end.

## What's next

From here, tasks can also come to you instead of you creating them:
Camelot syncs GitHub issues labeled `camelot` in as board tasks every 5
minutes. See the README's [Roadmap](../README.md#roadmap) for what's
coming next.
