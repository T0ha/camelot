%{
  title: "The .camelot folder",
  description: "How Camelot AI agents pick up per-project rules.",
  order: 1,
  published: true
}
---
# The `.camelot` folder

`.camelot/` is a directory inside **your project's git repository** — the
same repository 🏰 Camelot AI clones into every runner container before an
agent starts working on a task.

The part you author and commit is `.camelot/rules/`: markdown files holding
the instructions you want agents to follow in this project — your workflow,
your code style, your review checklist.

`.camelot/` may also hold other subfolders that Camelot creates and manages
by itself at runtime. Those are internal plumbing, described in one
paragraph at the end of this page; everything else here is about
`.camelot/rules/`.

## How a rule file actually reaches the agent

This is the part that surprises people, so it comes first.

**A file dropped into `.camelot/rules/` does nothing on its own.** Rule
files are *not* auto-discovered. That is different from `CLAUDE.md` and
`AGENTS.md`, which the agent CLI loads by itself from the repository root.
Camelot has no parser for `.camelot/` at all.

A rule file reaches the agent only when the **prompt template** used for the
task's current stage mentions it with an `@` file reference:

```
@.camelot/rules/feature-workflow.md
```

Camelot renders the template — substituting `{{title}}`, `{{description}}`,
`{{plan}}` and friends — and hands the result to the agent CLI as its
prompt, running in the cloned repository. The `@...` text is passed through
untouched: it is the CLI itself that resolves the path, relative to that
checkout, and inlines the file's content.

So the chain is:

1. You commit `.camelot/rules/my-rule.md` to the project repository.
2. A prompt template for the stage contains `@.camelot/rules/my-rule.md`.
3. The agent runs with the rule file's content inlined into its prompt.

Break any link and the rule is simply never read.

### What is wired up by default

Camelot ships three stage templates, picked by the task's stage:

| Stage slug  | When it runs   | Rule files mentioned                     |
|-------------|----------------|------------------------------------------|
| `planning`  | No plan yet    | *(none)*                                 |
| `execution` | A plan exists  | `feature-workflow.md`, `coding-style.md` |
| `pr_review` | A PR exists    | `pr-workflow.md`, `coding-style.md`      |

So out of the box only these three file names are picked up automatically —
a project providing them needs no template changes at all:

```
.camelot/
└── rules/
    ├── coding-style.md
    ├── feature-workflow.md
    └── pr-workflow.md
```

You can read the exact template bodies — including the `@` mentions — under
**`/prompts`** in the Camelot UI.

### Adding a rule file of your own

To introduce a rule under a different name, you have to mention it:

1. Add `.camelot/rules/my-rule.md` to your repository and commit it. The
   runner only ever sees committed files, since it works from a clone.
2. Open **`/prompts`** and create (or edit) a **project-scoped** template
   for the stage you want it in — slug `execution`, `pr_review` or
   `planning`.
3. Put `@.camelot/rules/my-rule.md` in the body, wherever you want the
   content pulled in.

A project-scoped template replaces the default for that stage: templates
resolve **project → user → system-global**, and the first match wins. The
project-scoped row is therefore the supported way to add, remove or reorder
rule mentions without changing any Camelot code.

### Auditing a rule that "isn't working"

If an agent ignores a rule, check in this order:

- Is the file committed and present on the branch the runner cloned?
- Is it `@`-mentioned by the template for **that stage**? A rule mentioned
  only by `execution` has no effect during PR review, and nothing is
  mentioned during planning by default.
- Is the mention in the template that actually won resolution — your
  project-scoped one, rather than the system-global default you were
  reading?

A rule file that no active template mentions is inert. That is a normal
state, not a bug: the Camelot repository itself keeps extra files in
`.camelot/rules/` that no default template references.

### Optional: the `.claude/rules` symlink

Some tooling — and some people — look only under the more widely recognized
`.claude/` directory. A single symlink keeps one copy of the content visible
under both paths:

```bash
ln -s ../.camelot/rules .claude/rules
```

The Camelot repository itself does this. It is a convenience, not a
requirement: the `@` mentions in the default templates point at
`.camelot/rules/`.

## Tell agents to leave `.camelot/` alone

Rules describe how an agent should work, so an agent that edits them
mid-task is rewriting its own instructions. Add a line like this to your
workflow rule file:

```markdown
**Never modify files in `.claude/` or `.camelot/` directories!**
```

Camelot's own `.camelot/rules/pr-workflow.md` carries a line just like it.

## Internal subfolders

Besides `rules/`, `.camelot/` may contain subfolders that Camelot creates
and fills in automatically inside the runner — task attachments, for
instance. They are not user content: don't hand-edit them, don't commit
them, and don't depend on their layout, which can change between releases.
