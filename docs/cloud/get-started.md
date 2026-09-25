%{
  title: "Get Started",
  description: "Sign in, connect GitHub, and ship your first AI-driven task on Camelot Cloud.",
  order: 1,
  published: true
}
---
# Get Started

This is a task-by-task walkthrough of Camelot's core loop: sign in,
connect GitHub, create a project, and create a task, then follow it
all the way to a merged pull request.

## Prerequisites

All you need is an email address — Camelot Cloud is open for anyone to
register, no invite required. This guide uses Camelot Cloud at
[app.camelotai.tech](https://app.camelotai.tech); everything below
assumes you're signed in there.

## 1. Sign in

There's no signup form and no password to set. Go to
[app.camelotai.tech/sign-in](https://app.camelotai.tech/sign-in) and pick
either way in:

- **Sign in with Github** (recommended) — the fastest path. One
  authorization on GitHub signs you in *and* connects the Camelot GitHub App
  to the repos you pick, so you land on the board ready to create projects
  with no extra setup step. If you haven't installed the app yet, GitHub
  offers *Install & Authorize* right on that screen.
- **Magic link** — enter your email and Camelot sends you a sign-in link
  that's valid for 10 minutes.

Both end up at the same account: if the verified primary email on your
GitHub account matches an existing Camelot user, that's you — no second
account is created, and you can keep using either method. Changing your
primary email on GitHub later doesn't fork your account either; Camelot asks
whether you want to move your address over.

On first sign-in, Camelot also generates an SSH keypair for you
automatically (more on that in
[Set up your profile](#2-set-up-your-profile)).

The first authenticated page you land on greets you with a short **setup
guide** covering exactly the four steps below: connect the GitHub App,
add a Claude token, create a project, create a task. Each step links
straight to the screen that completes it. Close it and a compact
checklist strip stays in the header until you're done — steps you
already satisfied (the GitHub App, if you signed in with GitHub) arrive
ticked, and the strip disappears for good once all of them are.

## 2. Set up your profile

Visit `/profile` to finish your personal setup:

- **SSH key** — Camelot already generated an Ed25519 keypair for you
  on first sign-in and mounts it into every runner automatically —
  there's nothing you need to do with it. It's only relevant if you
  want a runner to reach a repo that isn't covered by the GitHub App
  below (e.g. a private repo on another git host); in that case, copy
  the public key shown here and add it to that host.
- **GitHub App** — already done if you signed in with GitHub; the
  installation you authorized is listed here. Otherwise **Connect
  GitHub App** sends you to GitHub's installation flow; once
  installed, runners push over HTTPS using your installation and
  Camelot can poll PR/issue status for tasks you create. This is the
  recommended way to connect GitHub — most users don't need to touch
  the SSH key at all. **Disconnect** removes it any time.
- **Credentials** — add any API keys your agents need: a Claude,
  OpenAI, or Codex API key, or a generic secret. Pick a **Kind**, give
  it a **Name**, and paste the **Value**. These are encrypted at rest
  and shipped securely to runner containers. Pasted GitHub personal
  access tokens or OAuth tokens aren't supported — use the GitHub App
  above for git/GitHub access instead. Right now, **Claude Code is the
  only Agent CLI that's fully integrated and tested** — start with a
  Claude API key unless you know you need another provider. See
  [Setting up Claude Code](../agents/claude-code.md) or
  [Setting up Codex](../agents/codex.md) for a full walkthrough.

## 3. Create a project

Go to `/projects/new`. The form asks for four things, and only **Name**
is required:

- **Name** — Camelot derives a local path under `~/projects/<slug>` from
  it.
- **Description** — free text, shown on the project page.
- **GitHub Repository** — pick the repo from the list of repositories
  your GitHub App installation can see, so Camelot knows which repo to
  open PRs against and poll CI status for. Camelot authenticates those
  calls with whichever installation you connected in [Set up your
  profile](#2-set-up-your-profile) — no GitHub App connected just means
  unauthenticated API calls instead.
- **Runner Image** — leave blank unless this project needs a
  non-default runner image.

Everything else lives under **Advanced settings**, collapsed by default:

- **Path** — override the derived `~/projects/<slug>` location with the
  folder picker.
- **GitHub Owner** / **GitHub Repo** — filled in for you from the
  repository you picked, or auto-detected from a local repo's GitHub
  remote. Edit them only if you need to point somewhere else.
- The seven **Agent CLI overrides** — command prefix, executable, base
  args, environment variables, permission args by stage, internal tools
  and base retry delay. Each one applies to every task in this project,
  on top of the chosen agent CLI's defaults.

Editing an existing project shows the same split, plus **Status**
(active/archived) under Advanced settings; the section starts expanded
when the project already uses any of those fields.

Click **Save**.

## 4. (Optional) Customize prompts

At `/prompts` you can define system/user prompt templates, scoped
globally or to a specific project, with `{{title}}`, `{{description}}`,
and `{{plan}}` placeholders. Skip this to start — Camelot ships with
sensible defaults.

## 5. Create your first task

On the board (`/`), click **New Task** and fill in **Title**,
**Description**, **Project**, **CLI Agent**, **Priority**, and
**Attachments**, then **Create Task**. **CLI Agent** picks which Agent
CLI template (e.g. Claude Code, Codex) runs the task; a workspace admin
configures the available templates once under `/agents` — there's
nothing to set up per-project.

## 6. Review and approve the plan

Once an agent picks up the task, it moves to `planning` and the agent
writes a plan before touching any code. Open the task (`/tasks/:id`) to
read it under **Plan**, then either:

- **Approve Plan** — the agent starts executing, or
- **Request Changes** — send it back with feedback

Nothing gets implemented until you approve.

## 7. Watch it execute

After approval the task moves to `executing`, and the task page streams
the agent's live output in real time under **Live output** — assistant
messages, tool calls, and the final result, as they happen.

## 8. Review and merge the PR

When the agent finishes, it opens a pull request and the task moves to
`pr`. The task page shows a **PR #&lt;number&gt;** link straight to
GitHub — review the diff there as you normally would.

Camelot also polls GitHub for this PR every 2 minutes in the background:

- CI failures, requested changes, or new review comments automatically
  kick the task back to the agent, which pushes fixes without you having
  to ask.
- Once the PR is merged, the task moves to `done` on its own.

You can also act manually from the task page at any point: **Approve
PR** approves the pull request on GitHub and merges it (squash merge by
default), moving the task to `done` once the merge lands — if GitHub
refuses the merge (branch protection, a required check still failing, a
conflict) the task stays in `pr` and the page tells you why. **Request
Changes** sends it back to the agent instead.

Merging the PR (or clicking **Approve PR**) is the finish line — that's
your first task shipped end-to-end.

## What's next

From here, tasks can also come to you instead of you creating them:
Camelot syncs GitHub issues labeled `camelot` in as board tasks every 5
minutes. See the README's
[Roadmap](https://github.com/T0ha/camelot#roadmap) for what's coming
next.
