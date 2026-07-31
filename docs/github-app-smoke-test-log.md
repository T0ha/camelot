# GitHub App Auth Smoke Test

Date: 2026-07-31

This note records a live verification of the GitHub App integration
(`docs/github-app.md`) from inside a Camelot runner container.

Checked, all via the installation token (`camelotai-test[bot]`,
`ghs_…`) over HTTPS — no SSH key, no PAT:

- `gh auth status` confirms the active credential is the App
  installation token, with `gh auth git-credential` as the git
  credential helper.
- `git clone https://github.com/T0ha/camelot.git` into an isolated
  temp directory (not the existing SSH-remote `/workspace` checkout).
- `gh repo view` / `gh api repos/T0ha/camelot` for repo metadata.
- This commit + branch push, and the pull request it is attached to,
  exercise write access.
- A round-trip PR comment (post + retrieve) exercises comment
  read/write.

This file is expected to be removed once the smoke-test PR is closed.
