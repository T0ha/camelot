# Script for populating the database. You can run it as:
#
#     mix run priv/repo/seeds.exs
#
# Inside the script, you can read and write to any of your
# repositories directly:
#
#     Camelot.Repo.insert!(%Camelot.SomeSchema{})
#
# We recommend using the bang functions (`insert!`, `update!`
# and so on) as they will fail if something goes wrong.

alias Camelot.Prompts.PromptTemplate

existing = Ash.read!(PromptTemplate)

if !Enum.any?(existing, &(&1.slug == "planning" and is_nil(&1.project_id))) do
  Ash.create!(PromptTemplate, %{
    slug: "planning",
    name: "Planning Prompt",
    body: "Task: {{title}}\nDescription: {{description}}"
  })
end

if !Enum.any?(existing, &(&1.slug == "execution" and is_nil(&1.project_id))) do
  Ash.create!(PromptTemplate, %{
    slug: "execution",
    name: "Execution Prompt",
    body: "Task: {{title}}\nDescription: {{description}}\nPlan: {{plan}}"
  })
end
