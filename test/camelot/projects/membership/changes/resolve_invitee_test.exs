defmodule Camelot.Projects.Membership.Changes.ResolveInviteeTest do
  use Camelot.DataCase, async: false

  import Swoosh.TestAssertions

  alias Ash.Error.Invalid
  alias Ash.Resource.Info
  alias Camelot.Accounts.User
  alias Camelot.Projects.Membership
  alias Camelot.Projects.Membership.Changes.ResolveInvitee
  alias Camelot.Projects.Membership.Changes.SendProjectInviteEmail
  alias Camelot.Projects.Project

  require Ash.Query

  defp create_project!(owner, name \\ "proj-#{System.unique_integer()}") do
    Ash.create!(Project, %{name: name, path: "/tmp/#{name}"}, actor: owner)
  end

  defp invite(project, email, actor, opts \\ []) do
    Membership
    |> Ash.Changeset.for_create(
      :invite,
      Map.merge(%{project_id: project.id, email: email}, Map.new(opts)),
      actor: actor
    )
    |> Ash.create()
  end

  describe ":invite action" do
    test "admin can invite an unknown email, creating a new confirmed user and membership" do
      admin = Ash.Seed.seed!(User, %{email: "admin@e.com", role: :admin})
      project = create_project!(admin)

      assert {:ok, membership} = invite(project, "new-invitee@e.com", admin)

      assert membership.role == :member
      assert membership.project_id == project.id

      user = Ash.get!(User, membership.user_id, authorize?: false)
      assert to_string(user.email) == "new-invitee@e.com"
      assert user.confirmed_at

      assert_email_sent(subject: "You're invited to Camelot AI")
      assert_email_sent(subject: "You've been added to #{project.name} on Camelot AI")
    end

    test "project owner (non-admin) can invite an unknown email into their project" do
      owner = Ash.Seed.seed!(User, %{email: "owner@e.com", role: :user})
      project = create_project!(owner)

      assert {:ok, membership} = invite(project, "owner-invitee@e.com", owner)

      assert membership.role == :member
      user = Ash.get!(User, membership.user_id, authorize?: false)
      assert to_string(user.email) == "owner-invitee@e.com"
    end

    test "inviting a known email attaches the existing user without creating a duplicate or account email" do
      admin = Ash.Seed.seed!(User, %{email: "admin2@e.com", role: :admin})
      project = create_project!(admin)
      existing = Ash.Seed.seed!(User, %{email: "existing@e.com", role: :user})

      assert {:ok, membership} = invite(project, "existing@e.com", admin)

      assert membership.user_id == existing.id

      assert Enum.count(Ash.read!(Ash.Query.filter(User, email == "existing@e.com"), authorize?: false)) == 1

      refute_email_sent(subject: "You're invited to Camelot AI")
      assert_email_sent(subject: "You've been added to #{project.name} on Camelot AI")
    end

    test "a plain member (not owner, not admin) is rejected with a clear error" do
      owner = Ash.Seed.seed!(User, %{email: "owner2@e.com", role: :user})
      project = create_project!(owner)
      member = Ash.Seed.seed!(User, %{email: "member@e.com", role: :user})

      Membership
      |> Ash.Changeset.for_create(
        :create,
        %{project_id: project.id, user_id: member.id, role: :member},
        authorize?: false
      )
      |> Ash.create!()

      assert {:error, error} = invite(project, "someone-else@e.com", member)

      assert %Invalid{} = error

      assert Enum.any?(
               error.errors,
               &(&1.message =~ "admin or the project's owner")
             )
    end

    test "inviting someone already on the project is rejected, not a database error" do
      admin = Ash.Seed.seed!(User, %{email: "admin3@e.com", role: :admin})
      project = create_project!(admin)

      assert {:ok, _membership} = invite(project, "dupe@e.com", admin)
      assert {:error, error} = invite(project, "dupe@e.com", admin)

      assert %Invalid{} = error
      assert Enum.any?(error.errors, &(&1.message =~ "already a member"))
    end

    test "defaults to role :member" do
      admin = Ash.Seed.seed!(User, %{email: "admin4@e.com", role: :admin})
      project = create_project!(admin)

      assert {:ok, membership} = invite(project, "default-role@e.com", admin)
      assert membership.role == :member
    end

    test "accepts role: :owner from an authorized actor" do
      admin = Ash.Seed.seed!(User, %{email: "admin5@e.com", role: :admin})
      project = create_project!(admin)

      assert {:ok, membership} = invite(project, "co-owner@e.com", admin, role: :owner)
      assert membership.role == :owner
    end
  end

  describe "resource-level wiring" do
    test "ResolveInvitee and SendProjectInviteEmail are wired to :invite only" do
      invite_action = Info.action(Membership, :invite)

      assert Enum.any?(invite_action.changes, fn change ->
               match?(%{change: {ResolveInvitee, []}}, change)
             end),
             "ResolveInvitee should be wired into :invite. Configured changes: " <>
               inspect(invite_action.changes)

      assert Enum.any?(invite_action.changes, fn change ->
               match?(%{change: {SendProjectInviteEmail, []}}, change)
             end),
             "SendProjectInviteEmail should be wired into :invite. Configured changes: " <>
               inspect(invite_action.changes)

      resource_changes = Info.changes(Membership)

      refute Enum.any?(resource_changes, fn change ->
               change.change in [{ResolveInvitee, []}, {SendProjectInviteEmail, []}]
             end),
             "these changes should not be resource-wide"
    end
  end
end
