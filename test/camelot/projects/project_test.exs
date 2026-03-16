defmodule Camelot.Projects.ProjectTest do
  use Camelot.DataCase, async: true

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

    test "fails without required path" do
      assert {:error, _} =
               Ash.create(Project, %{name: "test"})
    end

    test "enforces unique name" do
      assert {:ok, _} = Ash.create(Project, @valid_attrs)

      assert {:error, _} =
               Ash.create(Project, %{
                 name: "my-project",
                 path: "/tmp/other"
               })
    end

    test "enforces unique path" do
      assert {:ok, _} = Ash.create(Project, @valid_attrs)

      assert {:error, _} =
               Ash.create(Project, %{
                 name: "other",
                 path: "/tmp/my-project"
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
