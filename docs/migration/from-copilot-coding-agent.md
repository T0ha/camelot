%{
  title: "Migrate from the GitHub Copilot coding agent",
  description: "Move from the GitHub Copilot coding agent to Camelot: a plan gate before code, your choice of agent, on your own credentials.",
  order: 3,
  published: true
}
---
# Migrate from the GitHub Copilot coding agent

## Who this is for

Your team already uses the GitHub Copilot coding agent's "assign an
issue, get a pull request" loop — Copilot researches the repository,
plans changes and implements them in the background, then opens a pull
request (see
[GitHub Copilot on GitHub.com and GitHub Mobile](https://docs.github.com/en/copilot/concepts/agents/coding-agent)
and
[Starting GitHub Copilot sessions](https://docs.github.com/en/copilot/how-tos/agents/copilot-coding-agent/using-copilot-to-work-on-an-issue)).
Camelot is for teams who like that loop and want two things on top: a
**plan gate** that pauses for your approval before any code is
written, and the freedom to **pick the agent** — Claude Code, Codex or
Kimi Code — running on **your own API credentials**.

## What carries over and what does not

| Copilot coding agent | Camelot |
|---|---|
| Assign work, get a pull request | The same loop: a task is planned, executed and turned into a PR |
| Runs in a cloud environment | The same idea — one isolated container per task |
| Billed through your Copilot plan | Does not carry — Camelot runs on your own Anthropic, OpenAI or Kimi API key |
| The agent is Copilot | You choose the agent CLI per task |

## What Camelot adds

- **A plan gate before code.** Every task starts in `planning`; the
  agent writes a plan and nothing is implemented until you approve it
  — on the board, or directly on the GitHub issue with a `/approve`
  comment or a 👍 reaction.
- **GitHub issues as the board.** Label an issue `camelot` to import
  it as a task; the plan, the approval and the merge summary all
  round-trip through the issue, which Camelot closes when the PR
  merges.
- **Your choice of agent** — [Claude Code](../agents/claude-code.md),
  [Codex](../agents/codex.md) or [Kimi Code](../agents/kimi-code.md) —
  on credentials you own, so usage bills against your own provider
  account.
- **Scheduling around usage limits** — hold cards back for your weekly
  quota or chosen run windows (see
  [Usage-aware scheduling](../guides/usage-scheduling.md)).
- **A self-host option** — run the whole thing on your own Docker
  Swarm cluster (see
  [Cluster runners](../self-hosting/cluster-runners.md)).

Camelot augments your developers: the agent proposes, a human
approves, and every change still lands as a pull request your team
reviews.

## The move in 10 minutes

Follow the same steps as in
[Migrate from Vibe Kanban](from-vibe-kanban.md#the-move-in-10-minutes) —
sign up at
[app.camelotai.tech](https://app.camelotai.tech/sign-in?utm_source=docs&utm_medium=content&utm_campaign=open-doors&utm_content=copilot-coding-agent)
with GitHub, import the repo as a project, and run one read-only first
task behind the plan gate.

The one difference: instead of relying on a Copilot plan, add a
Claude, OpenAI or Kimi credential at `/profile/api-keys` (see
[Setting up Claude Code](../agents/claude-code.md)), then label an
issue `camelot` — or create the task on the board directly.

## Sources

- [GitHub Copilot on GitHub.com and GitHub Mobile](https://docs.github.com/en/copilot/concepts/agents/coding-agent)
- [Starting GitHub Copilot sessions](https://docs.github.com/en/copilot/how-tos/agents/copilot-coding-agent/using-copilot-to-work-on-an-issue)
