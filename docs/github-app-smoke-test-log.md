# GitHub App Auth Smoke Test

Date: 2026-07-31

This note records a live verification of the GitHub App integration
(`docs/github-app.md`) from inside a Camelot runner container.

Checked, all via the installation token (`camelot-ai-board[bot]`,
`ghs_…`) over HTTPS — no SSH key, no PAT:

- `gh auth status` confirms the active credential is the App
  installation token, with `gh auth setup-git` wiring the git
  credential helper.
- `git clone https://github.com/T0ha/camelot.git` succeeded into an
  isolated temp directory (not the existing SSH-remote `/workspace`
  checkout), proving HTTPS clone works without an SSH key.
- `gh repo view`, `gh pr list`, and `gh issue list` for repo metadata.
- This commit + branch push, and the pull request it is attached to,
  exercise write access.
- A round-trip PR comment (post + retrieve) exercises comment
  read/write.

Unlike the previous run of this smoke test (PR #79), this PR is left
open intentionally so the results can be inspected before merge.
