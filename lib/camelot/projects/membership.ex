defmodule Camelot.Projects.Membership do
  @moduledoc """
  Join resource between `Camelot.Projects.Project` and
  `Camelot.Accounts.User`. A user may belong to many
  projects; a project may have many user collaborators.

  `role` is reserved for future permission checks and
  doesn't drive runtime behaviour today.
  """
  use Ash.Resource,
    domain: Camelot.Projects,
    data_layer: AshPostgres.DataLayer,
    authorizers: []

  @roles [:owner, :member]

  postgres do
    table("project_memberships")
    repo(Camelot.Repo)
  end

  attributes do
    attribute :role, :atom do
      allow_nil?(false)
      public?(true)
      default(:member)
      constraints(one_of: @roles)
    end

    timestamps()
  end

  relationships do
    belongs_to :project, Camelot.Projects.Project do
      allow_nil?(false)
      primary_key?(true)
    end

    belongs_to :user, Camelot.Accounts.User do
      allow_nil?(false)
      primary_key?(true)
    end
  end

  actions do
    defaults([:read, :destroy])

    create :create do
      primary?(true)
      accept([:role])

      argument :project_id, :uuid do
        allow_nil?(false)
      end

      argument :user_id, :uuid do
        allow_nil?(false)
      end

      change(manage_relationship(:project_id, :project, type: :append))
      change(manage_relationship(:user_id, :user, type: :append))
    end

    update :set_role do
      accept([:role])
    end
  end
end
