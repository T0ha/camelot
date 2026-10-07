defmodule Camelot.Projects.ProjectCloudRunnerTest do
  # Mutates the global :runner app env, so it can't run async.
  use Camelot.DataCase, async: false

  alias Ash.Error.Invalid
  alias Camelot.Projects.Project
  alias Camelot.Runtime.Runner.DockerEngine
  alias Camelot.Runtime.Runner.LocalPort
  alias Camelot.Runtime.Runner.Swarm

  setup do
    original = Application.get_env(:camelot, :runner)
    on_exit(fn -> Application.put_env(:camelot, :runner, original) end)
    :ok
  end

  defp put_backend(backend) do
    runner = Application.get_env(:camelot, :runner, [])
    Application.put_env(:camelot, :runner, Keyword.put(runner, :backend, backend))
  end

  describe "create with a cloud runner backend (DockerEngine, Swarm)" do
    for backend <- [DockerEngine, Swarm] do
      test "rejects a project without github_repo_url under #{inspect(backend)}" do
        put_backend(unquote(backend))

        assert {:error, %Invalid{errors: errors}} =
                 Ash.create(Project, %{name: "cloud-no-repo-#{System.unique_integer()}"})

        assert Enum.any?(errors, &(&1.field == :github_repo_url))
      end

      test "rejects a project with a blank github_repo_url under #{inspect(backend)}" do
        put_backend(unquote(backend))

        assert {:error, %Invalid{errors: errors}} =
                 Ash.create(Project, %{
                   name: "cloud-blank-repo-#{System.unique_integer()}",
                   github_repo_url: "   "
                 })

        assert Enum.any?(errors, &(&1.field == :github_repo_url))
      end

      test "accepts a project with github_repo_url under #{inspect(backend)}" do
        put_backend(unquote(backend))

        assert {:ok, project} =
                 Ash.create(Project, %{
                   name: "cloud-with-repo-#{System.unique_integer()}",
                   github_repo_url: "https://github.com/owner/repo"
                 })

        assert project.github_repo_url == "https://github.com/owner/repo"
      end
    end
  end

  describe "create with the LocalPort runner backend" do
    test "still accepts a path-only project (no regression)" do
      put_backend(LocalPort)

      assert {:ok, project} =
               Ash.create(Project, %{
                 name: "local-path-only-#{System.unique_integer()}",
                 path: "/tmp/local-path-only"
               })

      assert project.path == "/tmp/local-path-only"
      assert project.github_repo_url == nil
    end
  end

  describe "update under a cloud runner backend" do
    test "editing a pre-existing repo-less project is still allowed" do
      put_backend(LocalPort)

      {:ok, project} =
        Ash.create(Project, %{name: "legacy-#{System.unique_integer()}", path: "/tmp/legacy"})

      put_backend(Swarm)

      assert {:ok, updated} = Ash.update(project, %{description: "still editable"})
      assert updated.description == "still editable"
    end
  end
end
