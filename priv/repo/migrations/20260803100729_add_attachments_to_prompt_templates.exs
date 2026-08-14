defmodule Camelot.Repo.Migrations.AddAttachmentsToPromptTemplates do
  @moduledoc """
  Inserts a `{{attachments}}` placeholder line after
  `Description: {{description}}` in the seeded `planning`/
  `execution`/`pr_review` system prompt templates, so a dispatched
  agent is told which files are available under
  `.camelot/attachments/` in its workspace. Only updates rows whose
  body still matches the original seed text exactly, so a
  hand-customised system template is left alone.
  """

  use Ecto.Migration

  @planning_old """
  Task: {{title}}
  Description: {{description}}
  Pls, plan ahead\
  """

  @planning_new """
  Task: {{title}}
  Description: {{description}}
  {{attachments}}
  Pls, plan ahead\
  """

  @execution_old """
  Task: {{title}}
  Description: {{description}}
  Plan: {{plan}}
  Stirctly follow workflow in @.claude/rules/feature-workflow.md.
  Follow code style guide from @.claude/rules/coding-style.md\
  """

  @execution_new """
  Task: {{title}}
  Description: {{description}}
  {{attachments}}
  Plan: {{plan}}
  Stirctly follow workflow in @.claude/rules/feature-workflow.md.
  Follow code style guide from @.claude/rules/coding-style.md\
  """

  @pr_review_old """
  Task: {{title}}
  Description: {{description}}
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

  Strictly follow workflow in @.claude/rules/pr-workflow.md.
  Follow code style guide from @.claude/rules/coding-style.md\
  """

  def up do
    set_body("planning", @planning_old, @planning_new)
    set_body("execution", @execution_old, @execution_new)
    set_body("pr_review", @pr_review_old, @pr_review_new)
  end

  def down do
    set_body("planning", @planning_new, @planning_old)
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
