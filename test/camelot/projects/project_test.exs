defmodule Camelot.Projects.ProjectTest do
  use Camelot.DataCase, async: true

  alias Camelot.Projects.Membership
  alias Camelot.Projects.Project

  @valid_attrs %{
    name: "my-project",
    path: "/tmp/my-project"
  }

  describe "create" do
    test "creates a project with valid attributes" do
      assert {:ok, project} =
               Ash.create(Project, @valid_attrs)

      assert project.name == "my-project"
      assert project.path == "/tmp/my-project"
      assert project.status == :active
    end

    test "auto-adds the actor as a member" do
      require Ash.Query

      user = Ash.Seed.seed!(Camelot.Accounts.User, %{email: "member-#{System.unique_integer()}@x.com"})

      {:ok, project} =
        Ash.create(Project, %{name: "auto-mem-#{System.unique_integer()}", path: "/tmp/x"}, actor: user)

      memberships =
        Membership
        |> Ash.Query.filter(project_id == ^project.id)
        |> Ash.read!(authorize?: false)

      assert [%{user_id: uid, role: :member}] = memberships
      assert uid == user.id
    end

    test "creates without membership when no actor" do
      require Ash.Query

      {:ok, project} =
        Ash.create(Project, %{name: "no-actor-#{System.unique_integer()}", path: "/tmp/y"})

      memberships =
        Membership
        |> Ash.Query.filter(project_id == ^project.id)
        |> Ash.read!(authorize?: false)

      assert memberships == []
    end

    test "creates a project with all fields" do
      attrs =
        Map.merge(@valid_attrs, %{
          description: "A test project",
          github_repo_url: "https://github.com/org/repo",
          github_owner: "org",
          github_repo: "repo"
        })

      assert {:ok, project} = Ash.create(Project, attrs)
      assert project.description == "A test project"
      assert project.github_owner == "org"
    end

    test "fails without required name" do
      assert {:error, _} =
               Ash.create(Project, %{path: "/tmp/test"})
    end

    test "allows a project without a host path (hosted mode)" do
      assert {:ok, project} =
               Ash.create(Project, %{
                 name: "hosted-only",
                 github_repo_url: "https://github.com/owner/repo"
               })

      assert project.path == nil
      assert project.github_repo_url == "https://github.com/owner/repo"
    end

    test "enforces unique name" do
      assert {:ok, _} = Ash.create(Project, @valid_attrs)

      assert {:error, _} =
               Ash.create(Project, %{
                 name: "my-project",
                 path: "/tmp/other"
               })
    end
  end

  describe "update" do
    test "updates project attributes" do
      {:ok, project} = Ash.create(Project, @valid_attrs)

      assert {:ok, updated} =
               Ash.update(project, %{
                 description: "Updated"
               })

      assert updated.description == "Updated"
    end
  end

  describe "archive" do
    test "sets status to archived" do
      {:ok, project} = Ash.create(Project, @valid_attrs)
      assert project.status == :active

      assert {:ok, archived} =
               Ash.update(project, %{}, action: :archive)

      assert archived.status == :archived
    end
  end

  describe "read" do
    test "lists all projects" do
      {:ok, _} =
        Ash.create(Project, %{
          name: "p1",
          path: "/tmp/p1"
        })

      {:ok, _} =
        Ash.create(Project, %{
          name: "p2",
          path: "/tmp/p2"
        })

      assert {:ok, projects} = Ash.read(Project)
      assert length(projects) == 2
    end
  end

  describe "destroy" do
    test "deletes a project" do
      {:ok, project} = Ash.create(Project, @valid_attrs)
      assert :ok = Ash.destroy!(project)
      assert {:ok, []} = Ash.read(Project)
    end
  end
end
