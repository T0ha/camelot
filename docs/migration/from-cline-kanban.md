%{
  title: "Migrate from Cline Kanban",
  description: "Move from Cline Kanban to Camelot: a shared board backed by GitHub issues, with your choice of agent CLI.",
  order: 2,
  published: true
}
---
# Migrate from Cline Kanban

## Who this is for

You used Cline Kanban — Cline's CLI-agnostic, local, single-user
kanban board for driving coding agents (see the
[Cline Kanban announcement](https://cline.bot/blog/kanban)) — and now
need a board that is **shared with your team** and backed by your
GitHub repository instead of living on one machine.

## What carries over and what does not

| Cline Kanban | Camelot |
|---|---|
| A kanban board of agent-driven tasks | The same paradigm: cards are planned, executed and turned into pull requests |
| Local, single-user state | Does not migrate — recreate open items as GitHub issues labeled `camelot` |
| CLI-agnostic | Kept — pick the agent CLI per task |
| Solo workflow | Extended — the board is shared, and GitHub issues are the source of truth |

## What Camelot adds

- **GitHub issues as the board.** Label an issue `camelot` and it
  becomes a task; the agent's plan is posted as an issue comment, you
  approve it with a `/approve` comment or a 👍 reaction, and Camelot
  posts a summary and closes the issue when the pull request merges.
  Teammates follow along where they already work.
- **One container per task** — every run is isolated in its own
  container (see [Cluster runners](../self-hosting/cluster-runners.md)).
- **Your choice of agent** — [Claude Code](../agents/claude-code.md),
  [Codex](../agents/codex.md) or [Kimi Code](../agents/kimi-code.md),
  on your own API credentials.
- **Self-host or cloud** — run it yourself
  ([Cluster runners](../self-hosting/cluster-runners.md)) or sign in
  to the hosted version ([Get Started](../cloud/get-started.md)).
- Extras worth knowing once you are in:
  [usage-aware scheduling](../guides/usage-scheduling.md) and
  [recurring tasks](../guides/recurring-tasks.md).

## The move in 10 minutes

Follow the same steps as in
[Migrate from Vibe Kanban](from-vibe-kanban.md#the-move-in-10-minutes) —
sign up at
[app.camelotai.tech](https://app.camelotai.tech/sign-in?utm_source=docs&utm_medium=content&utm_campaign=open-doors&utm_content=cline-kanban),
add a credential, import the repo as a project, and run one read-only
first task behind the plan gate.

The one difference: there is nothing to export from Cline Kanban.
Recreate your open items as GitHub issues labeled `camelot` — each one
is imported as a task within about five minutes.

## Sources

- [Cline Kanban announcement](https://cline.bot/blog/kanban)
