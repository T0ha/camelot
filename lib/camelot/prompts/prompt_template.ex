defmodule Camelot.Prompts.PromptTemplate do
  @moduledoc """
  A prompt template that can be used to generate prompts
  for AI agent tasks. Supports variable interpolation with
  `{{variable}}` syntax and per-project overrides.
  """
  use Ash.Resource,
    domain: Camelot.Prompts,
    data_layer: AshPostgres.DataLayer,
    authorizers: []

  postgres do
    table("prompt_templates")
    repo(Camelot.Repo)
  end

  attributes do
    uuid_primary_key(:id)

    attribute :slug, :string do
      allow_nil?(false)
      public?(true)
      description("Unique identifier, e.g. planning, execution")
    end

    attribute :name, :string do
      allow_nil?(false)
      public?(true)
    end

    attribute :body, :string do
      allow_nil?(false)
      public?(true)
      description("Template text with {{variable}} placeholders")
    end

    attribute :description, :string do
      allow_nil?(true)
      public?(true)
      description("Help text describing the template")
    end

    timestamps()
  end

  relationships do
    belongs_to :project, Camelot.Projects.Project do
      allow_nil?(true)
      public?(true)
      attribute_writable?(true)
    end
  end

  identities do
    identity(:unique_slug_per_scope, [:slug, :project_id])
  end

  actions do
    defaults([:read, :destroy])

    create :create do
      primary?(true)
      accept([:slug, :name, :body, :description, :project_id])
    end

    update :update do
      primary?(true)
      accept([:name, :body, :description])
    end
  end
end
