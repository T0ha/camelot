defmodule Camelot.Github.IssueTrustTest do
  use Camelot.DataCase, async: true

  alias Camelot.Github.IssueTrust
  alias Camelot.Projects.Membership
  alias Camelot.Projects.Project

  setup do
    owner = user!(%{github_user_id: "1001"})
    member = user!(%{github_user_id: "1002"})
    _stranger_account = user!(%{github_user_id: "1003"})

    project =
      Ash.create!(
        Project,
        %{name: "trust-#{System.unique_integer([:positive])}", path: "/tmp/trust"},
        actor: owner
      )

    Ash.Seed.seed!(Membership, %{project_id: project.id, user_id: member.id, role: :member})

    other_project =
      Ash.create!(
        Project,
        %{name: "other-#{System.unique_integer([:positive])}", path: "/tmp/other"},
        actor: member
      )

    %{project: project, other_project: other_project}
  end

  describe "trusted?/2" do
    test "an owner is trusted", %{project: project} do
      assert IssueTrust.trusted?("1001", project.id)
    end

    test "a member is trusted", %{project: project} do
      assert IssueTrust.trusted?("1002", project.id)
    end

    test "accepts GitHub's integer ids", %{project: project} do
      assert IssueTrust.trusted?(1002, project.id)
    end

    test "a Camelot user without a membership is a stranger", %{project: project} do
      refute IssueTrust.trusted?("1003", project.id)
    end

    test "an unknown GitHub account is a stranger", %{project: project} do
      refute IssueTrust.trusted?("9999", project.id)
    end

    test "nil is never trusted", %{project: project} do
      refute IssueTrust.trusted?(nil, project.id)
    end

    test "membership is per project", %{other_project: other_project} do
      refute IssueTrust.trusted?("1001", other_project.id)
      assert IssueTrust.trusted?("1002", other_project.id)
    end
  end

  describe "owner?/2" do
    test "an owner is an owner", %{project: project} do
      assert IssueTrust.owner?("1001", project.id)
    end

    test "a member is not an owner", %{project: project} do
      refute IssueTrust.owner?("1002", project.id)
    end

    test "a stranger is not an owner", %{project: project} do
      refute IssueTrust.owner?("1003", project.id)
      refute IssueTrust.owner?(nil, project.id)
    end
  end

  describe "actor_id/1" do
    test "reads the GitHub user id of a comment, reaction or event" do
      assert IssueTrust.actor_id(%{"user" => %{"id" => 7}}) == "7"
      assert IssueTrust.actor_id(%{"actor" => %{"id" => 8}}) == "8"
      assert IssueTrust.actor_id(%{}) == nil
    end
  end

  describe "owner_approved?/3" do
    defp thumbs_up(user_id, created_at) do
      %{"content" => "+1", "user" => %{"id" => user_id}, "created_at" => created_at}
    end

    test "an owner's 👍 approves an unedited comment", %{project: project} do
      comment = %{"updated_at" => "2026-10-01T10:00:00Z"}

      assert IssueTrust.owner_approved?(
               comment,
               [thumbs_up(1001, "2026-10-01T11:00:00Z")],
               project.id
             )
    end

    test "a member's 👍 does not approve a stranger's comment", %{project: project} do
      comment = %{"updated_at" => "2026-10-01T10:00:00Z"}

      refute IssueTrust.owner_approved?(
               comment,
               [thumbs_up(1002, "2026-10-01T11:00:00Z")],
               project.id
             )
    end

    test "a stranger's 👍 approves nothing", %{project: project} do
      comment = %{"updated_at" => "2026-10-01T10:00:00Z"}

      refute IssueTrust.owner_approved?(
               comment,
               [thumbs_up(1003, "2026-10-01T11:00:00Z")],
               project.id
             )
    end

    test "a comment edited after the 👍 is no longer approved", %{project: project} do
      comment = %{"updated_at" => "2026-10-01T12:00:00Z"}

      refute IssueTrust.owner_approved?(
               comment,
               [thumbs_up(1001, "2026-10-01T11:00:00Z")],
               project.id
             )
    end

    test "other reactions do not approve", %{project: project} do
      comment = %{"updated_at" => "2026-10-01T10:00:00Z"}
      heart = %{"content" => "heart", "user" => %{"id" => 1001}, "created_at" => "2026-10-01T11:00:00Z"}

      refute IssueTrust.owner_approved?(comment, [heart], project.id)
    end
  end
end
