defmodule Camelot.Projects.EnvVarTest do
  use Camelot.DataCase, async: true

  alias Camelot.Projects.EnvVar
  alias Camelot.Projects.Project

  require Ash.Query

  defp project! do
    Ash.create!(Project, %{name: "proj-#{System.unique_integer([:positive])}", path: "/tmp/p"})
  end

  describe "encryption at rest" do
    test "value round-trips through create + load, ciphertext on disk" do
      {:ok, env_var} =
        Ash.create(EnvVar, %{key: "DATABASE_URL", value: "postgres://secret@db/app"})

      # Without loading, the cloaked attribute is not exposed as plaintext.
      refute Map.get(env_var, :value) == "postgres://secret@db/app"

      loaded =
        EnvVar
        |> Ash.Query.filter(id == ^env_var.id)
        |> Ash.Query.load(:value)
        |> Ash.read_one!()

      assert loaded.value == "postgres://secret@db/app"

      # Raw column holds ciphertext, not the plaintext value.
      %{rows: [[blob]]} =
        Repo.query!("SELECT encrypted_value FROM env_vars WHERE id = $1", [
          Ecto.UUID.dump!(env_var.id)
        ])

      assert is_binary(blob)
      refute String.contains?(blob, "postgres://secret@db/app")
    end
  end

  describe "key validation" do
    test "rejects keys that aren't valid env var names" do
      assert {:error, _} = Ash.create(EnvVar, %{key: "1BAD", value: "x"})
      assert {:error, _} = Ash.create(EnvVar, %{key: "has space", value: "x"})
      assert {:ok, _} = Ash.create(EnvVar, %{key: "_OK_1", value: "x"})
    end
  end

  describe "scope validation" do
    test "allows exactly one scope or global" do
      project = project!()

      assert {:ok, _} = Ash.create(EnvVar, %{key: "GLOBAL", value: "g"})
      assert {:ok, _} = Ash.create(EnvVar, %{key: "SCOPED", value: "p", project_id: project.id})
    end

    test "rejects more than one scope" do
      project = project!()
      user = user!()

      assert {:error, _} =
               Ash.create(EnvVar, %{
                 key: "AMBIGUOUS",
                 value: "x",
                 project_id: project.id,
                 user_id: user.id
               })
    end
  end

  describe "uniqueness per scope" do
    test "rejects duplicate key within the same project" do
      project = project!()

      assert {:ok, _} =
               Ash.create(EnvVar, %{key: "DUP", value: "a", project_id: project.id})

      assert {:error, _} =
               Ash.create(EnvVar, %{key: "DUP", value: "b", project_id: project.id})
    end

    test "rejects duplicate global key (all scopes nil)" do
      assert {:ok, _} = Ash.create(EnvVar, %{key: "GDUP", value: "a"})
      assert {:error, _} = Ash.create(EnvVar, %{key: "GDUP", value: "b"})
    end

    test "allows the same key in different projects" do
      p1 = project!()
      p2 = project!()

      assert {:ok, _} = Ash.create(EnvVar, %{key: "SAME", value: "a", project_id: p1.id})
      assert {:ok, _} = Ash.create(EnvVar, %{key: "SAME", value: "b", project_id: p2.id})
    end
  end

  describe "update" do
    test "rotates the encrypted value" do
      {:ok, env_var} = Ash.create(EnvVar, %{key: "TOKEN", value: "old"})

      {:ok, updated} = Ash.update(env_var, %{value: "new"})

      loaded =
        EnvVar
        |> Ash.Query.filter(id == ^updated.id)
        |> Ash.Query.load(:value)
        |> Ash.read_one!()

      assert loaded.value == "new"
    end
  end
end
