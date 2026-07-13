defmodule Camelot.Projects.Membership do
  @moduledoc """
  Join resource between `Camelot.Projects.Project` and
  `Camelot.Accounts.User`. A user may belong to many
  projects; a project may have many user collaborators.

  The creating user's membership is given `role: :owner`
  (see `Camelot.Projects.Project.Changes.AddActorAsMember`);
  `Project.owner_membership` uses that to resolve the
  owner's swarm node pin as a fallback in
  `Camelot.Runtime.AgentProcess.node_label_for/1`.
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
