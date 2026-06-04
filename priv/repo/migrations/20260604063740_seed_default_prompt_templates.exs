defmodule Camelot.Repo.Migrations.SeedDefaultPromptTemplates do
  @moduledoc """
  Seeds the three global prompt templates (`planning`,
  `execution`, `pr_review`) used by
  `Camelot.Agents.Changes.DispatchTasks`. Inserts are guarded
  by `WHERE NOT EXISTS` because the unique index on
  `(slug, project_id)` does not catch duplicates when
  `project_id IS NULL` (PostgreSQL treats NULLs as distinct).
  """

  use Ecto.Migration

  @planning_body """
  Task: {{title}}
  Description: {{description}}
  Pls, plan ahead\
  """

  @execution_body """
  Task: {{title}}
  Description: {{description}}
  Plan: {{plan}}
  Stirctly follow workflow in @.claude/rules/feature-workflow.md.
  Follow code style guide from @.claude/rules/coding-style.md\
  """

  @pr_review_body """
  Task: {{title}}
  Description: {{description}}
  Plan: {{plan}}

  PR: {{pr_url}}

  Check PR comments and review and fix issues.

  Strictly follow workflow in @.claude/rules/pr-workflow.md.
  Follow code style guide from @.claude/rules/coding-style.md\
  """

  def up do
    seed("planning", "Planning Prompt", @planning_body, nil)
    seed("execution", "Execution Prompt", @execution_body, nil)

    seed(
      "pr_review",
      "PR Review Prompt",
      @pr_review_body,
      "Prompt for addressing PR review comments"
    )
  end

  def down do
    execute("""
    DELETE FROM prompt_templates
     WHERE project_id IS NULL
       AND slug IN ('planning', 'execution', 'pr_review')
    """)
  end

  defp seed(slug, name, body, description) do
    execute("""
    INSERT INTO prompt_templates (slug, name, body, description)
    SELECT #{quote_str(slug)},
           #{quote_str(name)},
           #{quote_str(body)},
           #{quote_nullable(description)}
     WHERE NOT EXISTS (
       SELECT 1 FROM prompt_templates
        WHERE slug = #{quote_str(slug)}
          AND project_id IS NULL
     )
    """)
  end

  defp quote_str(s) do
    "'" <> String.replace(s, "'", "''") <> "'"
  end

  defp quote_nullable(nil), do: "NULL"
  defp quote_nullable(s), do: quote_str(s)
end
