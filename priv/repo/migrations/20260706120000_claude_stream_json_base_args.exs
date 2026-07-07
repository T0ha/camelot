defmodule Camelot.Repo.Migrations.ClaudeStreamJsonBaseArgs do
  @moduledoc """
  Switch the seeded `claude_code` template from
  `--output-format json` (a single JSON blob emitted only at
  process end) to `--output-format stream-json --verbose`
  (incremental NDJSON events). This keeps the exec stream warm
  on long runs and enables live output; the parser reads the
  final `type: "result"` event either way.

  Only rewrites rows still carrying the exact old value so a
  hand-customised template is left untouched.
  """
  use Ecto.Migration

  @new_args "ARRAY['--output-format','stream-json','--verbose']::text[]"
  @old_args "ARRAY['--output-format','json']::text[]"

  def up do
    execute("""
    UPDATE agent_templates
    SET base_args = #{@new_args}
    WHERE slug = 'claude_code' AND base_args = #{@old_args}
    """)
  end

  def down do
    execute("""
    UPDATE agent_templates
    SET base_args = #{@old_args}
    WHERE slug = 'claude_code' AND base_args = #{@new_args}
    """)
  end
end
