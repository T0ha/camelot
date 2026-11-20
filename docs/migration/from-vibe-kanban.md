%{
  title: "Migrate from Vibe Kanban",
  description: "Move from Vibe Kanban to Camelot: GitHub issues as the board, a plan gate, and your choice of agent.",
  order: 1,
  published: true
}
---
# Migrate from Vibe Kanban

## Who this is for

You used Vibe Kanban to manage AI coding agents on a kanban board and
are looking for a new home after its company announced it is shutting
down in April 2026 (see the
[shutdown notice](https://www.vibekanban.com/)). Along the way the
hosted, team-oriented features — shared issues and organizations —
were removed, and the project continues as community-maintained open
source (see the
[Nimbalyst post](https://nimbalyst.com/blog/vibe-kanban) covering the
transition). If that leaves you wanting a board that is shared with
your team and backed by something durable, Camelot is that board.

## What carries over and what does not

| Vibe Kanban | Camelot |
|---|---|
| A kanban board of tasks driven by AI agents | The same paradigm: a board where each card is planned, executed and turned into a pull request by an agent |
| Local, single-user data | Does not auto-migrate — recreate open items as GitHub issues or board tasks (10 minutes, below) |
| Hosted shared issues and orgs | Gone on Vibe Kanban's side; in Camelot the shared source of truth is your GitHub repository's issues |
| Choice of agent CLI | Kept — pick the agent per task |

## What Camelot adds

- **GitHub issues as the board, with the plan approved on the issue.**
  Label an issue `camelot` and it is imported as a task within about
  five minutes. The agent's plan is posted as an issue comment; you
  approve it by commenting `/approve`, reacting 👍, or adding the
  `camelot:approved` label — or request changes with any other
  comment. When the pull request merges, Camelot posts a summary
  comment and closes the issue. The whole loop lives where your team
  already works.
- **A plan gate on every task.** Nothing is implemented until you
  approve the plan — on the issue or in the Camelot UI.
- **Scheduling around usage limits.** Hold cards back for your weekly
  quota or chosen run windows, pin start times and deadlines — see
  [Usage-aware scheduling](../guides/usage-scheduling.md).
- **Recurring tasks.** Repeat a card daily, weekly or monthly — see
  [Recurring tasks](../guides/recurring-tasks.md).
- **One container per task.** Every agent run is isolated in its own
  container — see [Cluster runners](../self-hosting/cluster-runners.md).
- **Self-host or cloud.** Run it yourself with
  [Cluster runners](../self-hosting/cluster-runners.md) and a
  [GitHub App](../self-hosting/github-app.md), or sign in to the
  hosted version — see [Get Started](../cloud/get-started.md).
- **Your choice of agent.** [Claude Code](../agents/claude-code.md),
  [Codex](../agents/codex.md) or [Kimi Code](../agents/kimi-code.md),
  picked per task, on your own API credentials.

## The move in 10 minutes

1. **Sign up** at
   [app.camelotai.tech](https://app.camelotai.tech/sign-in?utm_source=docs&utm_medium=content&utm_campaign=open-doors&utm_content=vibe-kanban)
   with **Sign in with Github** — one authorization creates your
   account *and* connects the Camelot GitHub App to the repos you
   pick. (Self-hosting instead? Follow
   [Cluster runners](../self-hosting/cluster-runners.md).)
2. **GitHub is linked by the same sign-in.** If you used a magic link
   instead, connect the GitHub App later from `/profile/github`.
3. **Add your agent credential** at `/profile/api-keys` — a Claude API
   key or OAuth token per
   [Setting up Claude Code](../agents/claude-code.md).
4. **Import the repo**: create a project at `/projects/new` and pick
   the GitHub repository. Camelot clones it into each task's runner.
5. **Run one read-only first task**: on the board, click **New Task**
   with a title like "Explain what this repo does". The task moves to
   `planning` and the agent writes a plan without touching any code.
6. **Approve the plan** with **Approve Plan** on the task page.
   Nothing executes before this — you stay in control of the first
   run.

Optionally, label an existing GitHub issue `camelot` to import it as a
task — that is the fastest way to recreate your open items.

## Sources

- [Vibe Kanban shutdown notice](https://www.vibekanban.com/)
- [Nimbalyst on the Vibe Kanban transition](https://nimbalyst.com/blog/vibe-kanban)
- [Mark Ferree's review of Vibe Kanban](https://markferree.com/writing/vibe-kanban-review/)
