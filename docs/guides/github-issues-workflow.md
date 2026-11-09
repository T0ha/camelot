%{
  title: "GitHub issues workflow",
  description: "Run a task from its GitHub issue: labels, plan approval, and the merge summary.",
  order: 4,
  published: true
}
---
# GitHub issues workflow

As a project member, you can run a task's whole loop from its GitHub
issue: start the task, choose the agent and model, skip planning or
review the plan on the issue, and get a summary when the pull request
lands. Camelot talks to GitHub through the project owner's GitHub App
installation, so it needs the **Issues (read/write)** permission. See
[GitHub App setup](../self-hosting/github-app.md).

Here is what happens at each step:

| Step | When |
|---|---|
| Import labelled issues | About every 5 minutes |
| Post the plan on the issue | Right after the agent submits its plan |
| Read approvals and change requests | About every 2 minutes |
| Read issue comments while the PR is open | About every 2 minutes |
| Post the merge summary and close the issue | About every 2 minutes after the PR merges |

## Labels

| Label | Who sets it | Meaning |
|---|---|---|
| `camelot` | a project member | Import this issue as a task. |
| `camelot:agent:<slug>` | a project member | Run with this Agent CLI (its `slug` on `/agents`). If it's missing, the first agent by slug is used. |
| `camelot:model:<id>` | a project member | Pin the task's model. It must be one the agent offers the project owner. |
| `camelot:skip-plan` | a project member | Use the issue body as the plan and start in execution. |
| `camelot:approved` | a project member | Approve the pending plan, the same as `/approve`. |
| `camelot:invalid-config` | Camelot | The agent, model or credentials could not be resolved. See the comment Camelot posted. |
| `camelot:done` | Camelot | The task's PR was merged. |

An issue is imported **once**. Camelot reads the labels at that moment.
So add any `camelot:agent:`, `camelot:model:` or `camelot:skip-plan`
labels **before or together with** the `camelot` label. Changing them
after the task exists has no effect. To change the task's model, use
the board instead.

When the labels can't be resolved, Camelot creates no task. The agent
slug may be unknown, the agent may not offer that model to the project
owner, or the owner may lack the agent's credentials. In each case
Camelot comments once, listing the valid agent slugs or model ids, and
adds `camelot:invalid-config`. Fix the labels, or add the credentials,
and the next import picks the issue up and removes
`camelot:invalid-config`. Camelot comments only once while that label
is on the issue. To get a fresh explanation, remove the label.

The project **owner** becomes the task's creator. Credentials, model
choices and notifications all belong to the owner.

## Plan review on the issue

Without `camelot:skip-plan`, the task is planned as usual. When the
plan is submitted, Camelot posts it as an issue comment. Plans longer
than about 60,000 characters are truncated, with a link to the full
plan in Camelot. Then, from the issue:

- **Approve** by commenting `/approve` at the start of a comment,
  reacting 👍 on the plan comment, or adding `camelot:approved`.
  Execution starts. Other comments posted in the same check are passed
  to the agent as messages.
- **Request changes** with any other comment. The comment becomes a
  task message, and the task goes back to planning. Each new plan is
  posted as a **new** comment. 👍s and replies on an older plan comment
  never count for the new plan.

Approving in the Camelot UI posts "Plan approved in Camelot" on the
issue.

Only comments posted after the current plan comment are considered.
Camelot ignores its own comments.

## While the PR is open

Once the task has a pull request, the issue keeps working as a
feedback channel. Whenever the task is waiting for input, Camelot also
reads the issue, and a new comment requests changes the same way a new
PR comment does: the task is queued and the agent runs again.

- A **member's** comment counts as soon as it is posted.
- A **stranger's** comment counts once an **owner** 👍s it, and stops
  counting if it is edited after the 👍.
- `/approve` does nothing at this stage. Approve the PR on GitHub, or
  in Camelot, instead.
- Camelot ignores its own comments, and everything up to the plan
  comment, so plan-review feedback is not replayed.
- An approval on the PR still wins: it merges the PR, even when there
  are unhandled issue comments.

Each comment is acted on once. The issue is not read while the agent
is running, so a comment posted then is picked up after the run ends.
The agent sees these comments alongside the PR's, labelled
`[Issue #N]` and `[PR]`.

If reading the issue fails, Camelot checks the PR as usual.

## Merge

When the PR merges, Camelot posts one summary comment before the task
is marked done. The comment includes the PR link, the diff stats, the
approvers, the commit list, the PR body's `## Summary` section and the
executed plan. Camelot then adds `camelot:done`, removes
`camelot:approved` and `camelot:invalid-config`, and closes the issue
if it is still open.

If the PR is closed without merging, Camelot posts a short note and
leaves the issue open.

The summary is posted once. Camelot also checks for its own summary
comment on the issue, so it never posts a second one.

## Who counts

Camelot decides whose actions count by **project membership**, not by
GitHub's own author labels (such as "Contributor" or "Owner" on the
repository). A person counts as a **member** if they signed in to
Camelot with this GitHub account and have any role on the project. The
**owner** is the project owner, who is a member too. Everyone else is a
**stranger**.

| Action | Member | Stranger |
|---|---|---|
| Adds `camelot` (the latest label addition counts) | imports | ignored |
| Adds agent, model, skip-plan or approved labels | honoured | ignored |
| Authors an issue with `camelot:skip-plan` | plan skipped | planned anyway, until an **owner** 👍s the issue |
| Comments | change request, or `/approve` | ignored, until an **owner** 👍s that comment |
| 👍 on the plan comment | approves | ignored |

When an owner 👍s a stranger's comment, Camelot treats it as an
ordinary change request. A stranger's `/approve` never counts as an
approval, even with an owner's 👍. If a comment is edited after the
👍, the 👍 no longer counts.

## Caveats

- **Latency**: imports run about every 5 minutes, so a new issue can
  take a few minutes to appear as a task. Plan approval, change
  requests and merge handling are checked about every 2 minutes.
- **Stranger-authored issues**: an owner's 👍 on an issue is **not**
  voided by later edits. Vouch for the issue only once its text is
  final.

## For self-hosters

These details matter when you run Camelot yourself and operate the
background jobs.

The workflow runs through these modules:

| Step | Module | Cadence |
|---|---|---|
| Import labelled issues | `Camelot.Projects.Changes.SyncGithubIssues` | every 5 min (`Project :sync_github_issues`) |
| Post the plan | `Camelot.Board.Changes.PostPlanToIssue` via `Camelot.Board.Workers.PostToIssue` | right after `:submit_plan` |
| Read approvals and change requests | `Camelot.Board.Changes.CheckIssuePlan` | every 2 min (`Task :check_issue_plan` trigger) |
| Read issue comments while the PR is open | `Camelot.Board.Changes.CheckPrStatus` via `Camelot.Board.IssueComments` | every 2 min (`Task :check_pr_status` trigger) |
| Merge summary, labels, close | `Camelot.Board.Changes.PostMergeSummary` from `CheckPrStatus` | every 2 min (`Task :check_pr_status` trigger) |

Membership checks are done by `Camelot.Github.IssueTrust`, which matches
the GitHub account against `User.github_user_id`.

- **API cost**: each poll of a task waiting on plan review makes 3
  calls: the issue's comments, the plan comment's reactions and the
  issue. It makes 1 more for the issue's events while
  `camelot:approved` is on the issue, and 1 per stranger comment posted
  after the plan, for its reactions. All comments are fetched rather
  than using `since`, because GitHub's `since` filters on `updated_at`,
  and a reaction added later doesn't change it.
  While the PR is open, each poll of a task waiting for input makes 1
  more call for the issue's comments, plus 1 per stranger comment
  since the plan, for its reactions. Building the PR-review prompt
  makes the same calls once more.
- **Page sizes**: comments, reactions and events are read one
  100-entry page at a time. An issue with more than 100 comments, or
  100 events, is only partly visible to Camelot.
- **Merge summary retries**: the task moves to done even if posting the
  summary fails, for example when the Issues permission is missing.
  Nothing polls a done task, so the summary is not retried.
- **Issue comment marker**: `issue_comments_seen_at` records the
  newest issue comment (or owner 👍) handed to the agent while the PR
  is open. If reading the issue fails, a warning is logged and the
  marker is left alone.
- **Tasks imported before 2026-10-23**: the September issue sync
  imported issues as `GH#<n>: <title>` tasks without an `issue_number`.
  Those tasks have no issue link, so none of the above applies to
  them: no plan comment, no issue feedback while the PR is open, no
  merge summary. Backfilling `issue_number` from the title is possible
  but not done (see GH#196).
