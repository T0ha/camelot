defmodule Camelot.Repo.Migrations.UpdatePromptTemplatesCamelotRulesPath do
  @moduledoc """
  Updates the seeded `execution`/`pr_review` global prompt
  templates so their `@.claude/rules/...` references point at
  `.camelot/rules/...` instead, matching the move of rule files
  from `.claude/rules/` to `.camelot/rules/` (with `.claude/rules`
  now a symlink to `.camelot/rules`). Only updates rows whose body
  still matches the seed text produced by
  `20260803100729_add_attachments_to_prompt_templates.exs` exactly,
  so a hand-customised template is left alone.
  """

  use Ecto.Migration

  @execution_old """
  Task: {{title}}
  Description: {{description}}
  {{attachments}}
  Plan: {{plan}}
  Stirctly follow workflow in @.claude/rules/feature-workflow.md.
  Follow code style guide from @.claude/rules/coding-style.md\
  """

  @execution_new """
  Task: {{title}}
  Description: {{description}}
  {{attachments}}
  Plan: {{plan}}
  Stirctly follow workflow in @.camelot/rules/feature-workflow.md.
  Follow code style guide from @.camelot/rules/coding-style.md\
  """

  @pr_review_old """
  Task: {{title}}
  Description: {{description}}
  {{attachments}}
  Plan: {{plan}}

  PR: {{pr_url}}

  Check PR comments and review and fix issues.

  Strictly follow workflow in @.claude/rules/pr-workflow.md.
  Follow code style guide from @.claude/rules/coding-style.md\
  """

  @pr_review_new """
  Task: {{title}}
  Description: {{description}}
  {{attachments}}
  Plan: {{plan}}

  PR: {{pr_url}}

  Check PR comments and review and fix issues.

  Strictly follow workflow in @.camelot/rules/pr-workflow.md.
  Follow code style guide from @.camelot/rules/coding-style.md\
  """

  def up do
    set_body("execution", @execution_old, @execution_new)
    set_body("pr_review", @pr_review_old, @pr_review_new)
  end

  def down do
    set_body("execution", @execution_new, @execution_old)
    set_body("pr_review", @pr_review_new, @pr_review_old)
  end

  defp set_body(slug, from_body, to_body) do
    repo().query!(
      """
      UPDATE prompt_templates
         SET body = $1
       WHERE slug = $2
         AND project_id IS NULL
         AND user_id IS NULL
         AND body = $3
      """,
      [to_body, slug, from_body]
    )
  end
end
