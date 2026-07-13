defmodule Camelot.Settings.SystemSettingTest do
  use Camelot.DataCase, async: true

  alias Camelot.Accounts.User
  alias Camelot.Settings.SystemSetting

  describe "read" do
    test "is readable without an actor" do
      Ash.Seed.seed!(SystemSetting, %{default_swarm_node_label: "gpu-1"})

      assert {:ok, [setting]} = Ash.read(SystemSetting, actor: nil)
      assert setting.default_swarm_node_label == "gpu-1"
    end
  end

  describe "set_default_swarm_node_label" do
    test "an admin can set the global default, creating the singleton row" do
      admin = Ash.Seed.seed!(User, %{email: "admin-#{System.unique_integer()}@example.com", role: :admin})

      assert {:ok, updated} =
               SystemSetting
               |> Ash.Changeset.for_create(
                 :set_default_swarm_node_label,
                 %{default_swarm_node_label: "gpu-5"},
                 actor: admin
               )
               |> Ash.create()

      assert updated.default_swarm_node_label == "gpu-5"
    end

    test "calling it again upserts the same row instead of creating a duplicate" do
      admin = Ash.Seed.seed!(User, %{email: "admin-#{System.unique_integer()}@example.com", role: :admin})

      {:ok, _first} =
        SystemSetting
        |> Ash.Changeset.for_create(
          :set_default_swarm_node_label,
          %{default_swarm_node_label: "gpu-1"},
          actor: admin
        )
        |> Ash.create()

      {:ok, second} =
        SystemSetting
        |> Ash.Changeset.for_create(
          :set_default_swarm_node_label,
          %{default_swarm_node_label: "gpu-2"},
          actor: admin
        )
        |> Ash.create()

      assert second.default_swarm_node_label == "gpu-2"
      assert {:ok, [only]} = Ash.read(SystemSetting, authorize?: false)
      assert only.default_swarm_node_label == "gpu-2"
    end

    test "a non-admin cannot set the global default" do
      user = Ash.Seed.seed!(User, %{email: "user-#{System.unique_integer()}@example.com"})

      assert {:error, _} =
               SystemSetting
               |> Ash.Changeset.for_create(
                 :set_default_swarm_node_label,
                 %{default_swarm_node_label: "gpu-5"},
                 actor: user
               )
               |> Ash.create()
    end
  end

  describe "singleton identity" do
    test "a second row rejects the unique key constraint" do
      Ash.Seed.seed!(SystemSetting, %{})

      assert_raise Ash.Error.Invalid, fn ->
        Ash.Seed.seed!(SystemSetting, %{})
      end
    end
  end

  describe "Camelot.Settings.default_swarm_node_label/0" do
    test "returns nil when no row exists yet" do
      assert Camelot.Settings.default_swarm_node_label() == nil
    end

    test "returns the configured label" do
      Ash.Seed.seed!(SystemSetting, %{default_swarm_node_label: "gpu-9"})
      assert Camelot.Settings.default_swarm_node_label() == "gpu-9"
    end
  end
end
