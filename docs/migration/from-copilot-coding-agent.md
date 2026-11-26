%{
  title: "Migrate from the GitHub Copilot coding agent",
  description: "Move from the GitHub Copilot coding agent to Camelot AI: a plan gate before code, your choice of agent, on your own credentials.",
  order: 3,
  published: true
}
---
# Migrate from the GitHub Copilot coding agent

## Who this is for

Your team already uses the GitHub Copilot coding agent's "assign an
issue, get a pull request" loop: Copilot researches the repository,
plans changes and implements them in the background, then opens a pull
request (see
[GitHub Copilot on GitHub.com and GitHub Mobile](https://docs.github.com/en/copilot/concepts/agents/coding-agent)
and
[Starting GitHub Copilot sessions](https://docs.github.com/en/copilot/how-tos/agents/copilot-coding-agent/using-copilot-to-work-on-an-issue)).
Camelot AI is for teams who like that loop and want two things on top:
a **plan gate** that pauses for your approval before any code is
written, and the freedom to **pick the agent** (Claude Code, Codex or
Kimi Code) running on **your own API credentials**.

## What carries over and what does not

| Copilot coding agent | Camelot AI |
|---|---|
| Assign work, get a pull request | The same loop: a task is planned, executed and turned into a PR |
| Runs in a cloud environment | The same idea: one isolated container per task |
| Billed through your Copilot plan | Does not carry; Camelot AI runs on your own Anthropic, OpenAI or Kimi API key |
| The agent is Copilot | You choose the agent CLI per task |

## What Camelot AI adds

- **A plan gate before code.** Every task starts in `planning`; the
  agent writes a plan and nothing is implemented until you approve it,
  on the board or directly on the GitHub issue with a `/approve`
  comment or a 👍 reaction.
- **GitHub issues as the board.** Label an issue `camelot` to import
  it as a task; the plan, the approval and the merge summary all
  round-trip through the issue, which Camelot AI closes when the PR
  merges.
- **Your choice of agent**: [Claude Code](../agents/claude-code.md),
  [Codex](../agents/codex.md) or [Kimi Code](../agents/kimi-code.md),
  on credentials you own, so usage bills against your own provider
  account.
- **Scheduling around usage limits**: hold cards back for your weekly
  quota or chosen run windows (see
  [Usage-aware scheduling](../guides/usage-scheduling.md)).
- **A self-host option**: run the whole thing on your own Docker
  Swarm cluster (see
  [Cluster runners](../self-hosting/cluster-runners.md)).

Camelot AI augments your developers: the agent proposes, a human
approves, and every change still lands as a pull request your team
reviews.

## The move in 10 minutes

1. **Sign up** at
   [app.camelotai.tech](https://app.camelotai.tech/sign-in?utm_source=docs&utm_medium=content&utm_campaign=open-doors&utm_content=copilot-coding-agent)
   with **Sign in with Github**. One authorization creates your
   account *and* connects the Camelot AI GitHub App to the repos you
   pick. (Self-hosting instead? Follow
   [Cluster runners](../self-hosting/cluster-runners.md).)
2. **Add your agent credential** at `/profile/api-keys`: a Claude,
   OpenAI or Kimi key instead of relying on a Copilot plan. See
   [Setting up Claude Code](../agents/claude-code.md).
3. **Import the repo**: create a project at `/projects/new` and pick
   the GitHub repository. Camelot AI clones it into each task's
   runner.
4. **Run one read-only first task**: on the board, click **New Task**
   with a title like "Explain what this repo does". The task moves to
   `planning` and the agent writes a plan without touching any code.
5. **Approve the plan** with **Approve Plan** on the task page.
   Nothing executes before this; you stay in control of the first
   run.
6. **Or drive it from an issue**: label an existing GitHub issue
   `camelot` and it is imported as a task within about five minutes;
   the plan and approval round-trip through the issue, just like the
   loop you already know.

## Sources

- [GitHub Copilot on GitHub.com and GitHub Mobile](https://docs.github.com/en/copilot/concepts/agents/coding-agent)
- [Starting GitHub Copilot sessions](https://docs.github.com/en/copilot/how-tos/agents/copilot-coding-agent/using-copilot-to-work-on-an-issue)
