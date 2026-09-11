# Contributing

How work flows from a branch to production, and what CI does at each step.

## Branching model

```
feature / camelot task branch
        │  PR  ─────────────────────────────► develop        (integration)
        │                                       │
        │                          release PR (automatic)
        │                                       ▼
        └──────────────────────────────────►  main            (production)
```

- **`develop`** is the integration branch. **Every** contribution — human or
  agent — targets `develop`.
- **`main`** is release-only and mirrors production. It is updated
  exclusively through the rolling `develop` → `main` release PR that CI
  opens for you. PRs to `main` from anything other than `develop` fail the
  `main-only-from-develop` check and get a comment asking you to retarget.
- Branch names: `feat/*`, `fix/*`, `docs/*`, `chore/*`. Agent branches are
  created as `camelot/task-<uuid>`.

## Opening a PR

1. Branch off `develop`.
2. Write tests first, then the code.
3. Before pushing, run locally:

   ```sh
   mix precommit        # compile --warnings-as-errors, deps.unlock, format, test
   mix credo            # style / consistency (CI gate)
   mix dialyzer         # types (CI gate)
   ```

4. Push and open the PR **against `develop`**.
5. Keep the PR green: the same checks run on every push.

## Pipelines

| Workflow | Trigger | What it does |
|---|---|---|
| `push-checks.yml` | push to any branch except `main` / `develop` | Calls `code-checks.yml` |
| `code-checks.yml` | `workflow_call` | `mix format --check-formatted`, `mix credo`, `mix dialyzer`, `mix test` |
| `pr-base-guard.yml` | PR targeting `main` | Fails unless the PR head is this repo's `develop` |
| `build-docker-image.yml` | push to `develop` | Checks → multi-arch image (`ghcr.io/t0ha/camelotai`) → deploy to test → open/refresh the release PR |
| `promote-develop.yml` | last stage of the `develop` pipeline, or `workflow_dispatch` | Opens or refreshes the `develop` → `main` release PR |
| `deploy-production.yml` | push to `main` | Resolves the image built for the merged `develop` commit and deploys it to production |
| `deploy-docs-proxy.yml` | push to `develop` touching `docs-proxy/**` | Builds and deploys the docs proxy (gated on the `DEPLOY_DOCS_PROXY` variable) |
| `runner-images.yml` | push to `main` / `develop` touching `runner-images/**` | Builds the agent runner images |

### Only the newest run survives

Every push-triggered workflow declares:

```yaml
concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true
```

Merging several PRs into `develop` in a row therefore leaves exactly one
live run per pipeline — the one for the newest commit. Superseded runs are
cancelled instead of queueing up behind it, so you never wait on (or
deploy) an already-stale commit. Cancelled runs show up as ⏹ "cancelled",
which is expected and not a failure.

Because a cancellation can in principle land while an older run is inside
its CapRover deploy step, a newer deploy immediately supersedes it; if a
test deploy ever looks half-applied, re-run the newest `develop` pipeline.

## The automatic release PR

When the whole `develop` pipeline is green — checks, multi-arch image
build, deploy to test — `promote-develop.yml` runs and:

1. Finds the open `develop` → `main` PR, or opens one titled
   `Release: develop → main`.
2. Rewrites the body with every commit and **every PR merged into
   `develop` since `main`**. A release PR that is still open therefore
   accumulates ("stacks") the PRs of each later `develop` pipeline instead
   of a second, competing PR being opened.
3. Comments on the PR with the newly stacked PR numbers, so reviewers see
   what changed since they last looked.
4. Publishes a successful `main-only-from-develop` status on the `develop`
   tip (see *Known quirks*).

Nothing is promoted automatically: a human still reviews and merges the
release PR. That merge is what deploys to production.

### Merge the release PR with a merge commit

`deploy-production.yml` never rebuilds. It takes `HEAD^2` of the new `main`
commit — the merged `develop` tip — and deploys the image already built and
tested for that SHA. Squashing or rebasing the release PR produces a commit
with no second parent, so the deploy fails with
`main must be updated via a merge commit from develop`.

## Hotfixes

There is no `main`-only hotfix path: a fix must pass through `develop` so
that an image exists for it and so `main` never diverges. For an urgent
fix, open the PR against `develop`, get it merged, and merge the release PR
as soon as the `develop` pipeline goes green.

## Maintainer setup

Repository settings CI depends on:

- **Ruleset on `main`** (Settings → Rules), already configured:
  - a pull request with at least one approval; deletions and force pushes
    blocked;
  - `main-only-from-develop` as a **required status check**, which makes
    the guard blocking rather than advisory;
  - *allowed merge methods* restricted to **merge commit** only, so the
    release PR cannot be squashed (see above).

  Repository admins are bypass actors, so an emergency merge is still
  possible — at the cost of the production deploy failing to resolve an
  image (see above).
- **Actions → Workflow permissions**: "Read and write permissions". The
  release-PR job needs `pull-requests: write` and `statuses: write`.
- **Environments** `test` and `production` hold the CapRover credentials
  (`APP_TOKEN`, `CAPROVER_SERVER`, `APP_NAME`) and the docs CDN variables.

### Known quirks

- **PRs opened with `GITHUB_TOKEN` do not start workflows.** That is why
  `promote-develop.yml` publishes the `main-only-from-develop` status
  itself — otherwise a required check that can never report would block the
  release PR forever. The job name in `pr-base-guard.yml` and
  `GUARD_CONTEXT` in `promote-develop.yml` must stay identical.
- `promote-develop.yml` is invoked as a job of `build-docker-image.yml`
  rather than via `workflow_run`, so it always runs the version of the file
  that is on `develop` — no waiting for it to reach the default branch.
- The release PR still needs a human approval; the automation only prepares
  it.
