%{
  title: "Migrate from Cline Kanban",
  description: "Move from Cline Kanban to Camelot AI: a shared board backed by GitHub issues, with your choice of agent CLI.",
  order: 2,
  published: true
}
---
# Migrate from Cline Kanban

## Who this is for

You used Cline Kanban, Cline's CLI-agnostic, local, single-user
kanban board for driving coding agents (see the
[Cline Kanban announcement](https://cline.bot/blog/kanban)), and now
need a board that is **shared with your team** and backed by your
GitHub repository instead of living on one machine.

## What carries over and what does not

| Cline Kanban | Camelot AI |
|---|---|
| A kanban board of agent-driven tasks | The same paradigm: cards are planned, executed and turned into pull requests |
| Local, single-user state | Does not migrate; recreate open items as GitHub issues labeled `camelot` |
| CLI-agnostic | Kept; pick the agent CLI per task |
| Solo workflow | Extended; the board is shared, and GitHub issues are the source of truth |

## What Camelot AI adds

- **GitHub issues as the board.** Label an issue `camelot` and it
  becomes a task; the agent's plan is posted as an issue comment, you
  approve it with a `/approve` comment or a 👍 reaction, and Camelot AI
  posts a summary and closes the issue when the pull request merges.
  Teammates follow along where they already work.
- **Projects with multiple collaborators.** Invite teammates by email
  from the project page and share the board with them.
- **One container per task**: every run is isolated in its own
  container (see [Cluster runners](../self-hosting/cluster-runners.md)).
- **Your choice of agent**: [Claude Code](../agents/claude-code.md),
  [Codex](../agents/codex.md) or [Kimi Code](../agents/kimi-code.md),
  on your own API credentials.
- **Self-host or cloud**: run it yourself
  ([Cluster runners](../self-hosting/cluster-runners.md)) or sign in
  to the hosted version ([Get Started](../cloud/get-started.md)).
- Extras worth knowing once you are in:
  [usage-aware scheduling](../guides/usage-scheduling.md) and
  [recurring tasks](../guides/recurring-tasks.md).

## The move in 10 minutes

There is nothing to export from Cline Kanban, so the move is a fresh
setup plus recreating your open items:

1. **Sign up** at
   [app.camelotai.tech](https://app.camelotai.tech/sign-in?utm_source=docs&utm_medium=content&utm_campaign=open-doors&utm_content=cline-kanban)
   with **Sign in with Github**. One authorization creates your
   account *and* connects the Camelot AI GitHub App to the repos you
   pick. (Self-hosting instead? Follow
   [Cluster runners](../self-hosting/cluster-runners.md).)
2. **Add your agent credential** at `/profile/api-keys`: a Claude API
   key or OAuth token per
   [Setting up Claude Code](../agents/claude-code.md).
3. **Import the repo**: create a project at `/projects/new` and pick
   the GitHub repository. Camelot AI clones it into each task's
   runner.
4. **Invite your team** (optional): open the project and add
   collaborators by email.
5. **Run one read-only first task**: on the board, click **New Task**
   with a title like "Explain what this repo does". The task moves to
   `planning` and the agent writes a plan without touching any code.
6. **Approve the plan** with **Approve Plan** on the task page.
   Nothing executes before this; you stay in control of the first
   run.
7. **Recreate your open items**: label each existing GitHub issue
   `camelot` and it is imported as a task within about five minutes.

## Sources

- [Cline Kanban announcement](https://cline.bot/blog/kanban)
