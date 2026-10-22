# GitHub issues workflow

A project member can run a task's whole loop from its GitHub issue:
attach the issue, pick the agent and model, skip planning or review the
plan, and get a summary when the pull request lands. Camelot talks to
GitHub through the project owner's GitHub App installation (see
`docs/self-hosting/github-app.md`). It needs the **Issues (read/write)**
permission.

The moving parts:

| Step | Module | Cadence |
|---|---|---|
| Import labelled issues | `Camelot.Projects.Changes.SyncGithubIssues` | every 5 min (`Project :sync_github_issues`) |
| Post the plan | `Camelot.Board.Changes.PostPlanToIssue` via `Camelot.Board.Workers.PostToIssue` | right after `:submit_plan` |
| Read approvals and change requests | `Camelot.Board.Changes.CheckIssuePlan` | every 2 min (`Task :check_issue_plan` trigger) |
| Merge summary, labels, close | `Camelot.Board.Changes.PostMergeSummary` from `CheckPrStatus` | every 2 min (`Task :check_pr_status` trigger) |

## Labels

| Label | Who sets it | Meaning |
|---|---|---|
| `camelot` | a project member | Import this issue as a task. |
| `camelot:agent:<slug>` | a project member | Run with this Agent CLI (its `slug` on `/agents`). If it's missing, the first agent by slug is used. |
| `camelot:model:<id>` | a project member | Pin the task's model (`next_model`). It must be one the agent offers the project owner. |
| `camelot:skip-plan` | a project member | Use the issue body as the plan and start in execution. |
| `camelot:approved` | a project member | Approve the pending plan, the same as `/approve`. |
| `camelot:invalid-config` | Camelot | The agent, model or credentials could not be resolved. See the comment Camelot posted. |
| `camelot:done` | Camelot | The task's PR was merged. |

The issue is imported **once**. Camelot keys it on the project and the
issue number, and reads the labels at that moment. So add any
`camelot:agent:` / `camelot:model:` / `camelot:skip-plan` labels
**before or together with** the `camelot` label. Changing them after
the task exists has no effect; change the task's model on the board
instead.

When the labels can't be resolved, Camelot creates no task. It might
not know the agent slug, the agent might not offer the model to the
project owner, or the owner might lack the agent's credentials. In
each case Camelot comments once, listing the valid agent slugs or
model ids, and adds `camelot:invalid-config`. Fix the labels, or add
the credentials, and the next sync imports the issue and removes
`camelot:invalid-config`. Camelot comments only once while the label
is on the issue. To get a fresh explanation, remove the label.

The project **owner** becomes the task's creator. Credentials, model
discovery and notifications are all theirs.

## Plan review on the issue

Without `camelot:skip-plan`, the task is planned as usual. When the
plan is submitted, Camelot posts it as an issue comment, starting with
a hidden `<!-- camelot:plan task=<id> -->` marker. A plan over ~60k
characters is truncated, with a link to `/tasks/:id/plan`. Then, from
the issue:

- **Approve** by commenting `/approve` (at the start of the comment),
  reacting 👍 on the plan comment, or adding `camelot:approved`.
  Execution starts. Any other comments posted in the same poll are
  passed to the agent as messages.
- **Request changes** with any other comment. The comment becomes a
  task message and the task goes back to planning. Each re-plan is
  posted as a **new** comment. 👍s and replies on an older plan
  comment never count for the new plan.

Approving in the Camelot UI posts "Plan approved in Camelot" on the
issue.

Only comments posted after the current plan comment are considered.
Camelot ignores its own comments (the App bot's).

## Merge

When the PR merges, Camelot posts one summary comment before the card
moves to `:done`. The comment has the PR link, the diff stats, the
approvers, the commit list, the PR body's `## Summary` section and the
executed plan. Camelot then adds `camelot:done`, removes
`camelot:approved` / `camelot:invalid-config`, and closes the issue if
it is still open.

If the PR is closed without merging, Camelot posts a short note and
leaves the issue open.

The summary is posted once. `merge_summary_posted_at` records it, and a
`<!-- camelot:merge-summary task=<id> -->` marker comment on the issue
is a second guard. Adding and removing labels, and closing the issue,
are best effort.

## Trust

`Camelot.Github.IssueTrust` decides whose actions count. GitHub's
`author_association` is **not** used:

- **Member**: a Camelot user who signed in with this GitHub account
  (`User.github_user_id`) and has any role on the project.
- **Owner**: the same, with role `:owner`.
- **Stranger**: everyone else.

| Action | Member | Stranger |
|---|---|---|
| Adds `camelot` (the latest `labeled` event counts) | imports | ignored |
| Adds agent / model / skip-plan / approved labels | honoured | ignored |
| Authors an issue with `camelot:skip-plan` | plan skipped | planned anyway, until an **owner** 👍s the issue |
| Comments | change request, or `/approve` | ignored, until an **owner** 👍s that comment |
| 👍 on the plan comment | approves | ignored |

Once an owner 👍s a stranger's comment, Camelot treats it as an
ordinary change request. A stranger's `/approve` is never an approval,
even with an owner's 👍. If the comment is edited after the 👍
(`updated_at` is later than the reaction), the 👍 no longer counts.

## Caveats

- **Latency**: imports run every 5 minutes. Plan approval, change
  requests and merge handling are polled every 2 minutes.
- **API cost**: each poll of a task waiting on plan review makes 3
  calls: the issue's comments, the plan comment's reactions and the
  issue. It makes 1 more for the issue's events while `camelot:approved`
  is on the issue, and 1 per stranger comment posted after the plan,
  for its reactions. All comments are fetched rather than
  `since: issue_comments_seen_at`, because GitHub's `since` filters on
  `updated_at`, and a reaction added later doesn't change it.
- **Page sizes**: comments, reactions and events are read one
  100-entry page at a time. An issue with more than 100 comments, or
  100 events, is only partly visible.
- **Stranger-authored issues**: the owner's 👍 on the issue is **not**
  voided by later edits. GitHub's REST API can't tell a body edit from
  a label change, because both bump `updated_at`. Vouch for the issue
  only once its text is final.
- **Merge summary retries**: the card moves to `:done` even if posting
  the summary fails, for example when the Issues permission is
  missing. Nothing polls a `:done` task, so the summary is not retried.
