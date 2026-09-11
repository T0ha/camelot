defmodule Camelot.Runtime.SecretSyncTest do
  use ExUnit.Case, async: true

  alias Camelot.Runtime.SecretSync

  describe "secret_name/2" do
    test "maps :ssh_private_key to the short ssh_pk suffix (Docker's 64-char cap)" do
      assert SecretSync.secret_name("user-1", :ssh_private_key) == "camelot_user_user-1_ssh_pk"
    end

    test "other kinds use the atom name verbatim" do
      assert SecretSync.secret_name("user-1", :claude_api_key) == "camelot_user_user-1_claude_api_key"
    end
  end

  describe "task_secret_name/2" do
    test "builds a per-task name distinct from the per-user scheme" do
      assert SecretSync.task_secret_name("task-1", :github_app_token) == "camelot_task_task-1_gh_token"
    end
  end

  describe "delete_result/2" do
    test "a 2xx delete succeeds" do
      assert SecretSync.delete_result(200, %{}) == :ok
      assert SecretSync.delete_result(204, %{}) == :ok
    end

    test "an already-absent secret counts as deleted" do
      assert SecretSync.delete_result(404, %{"message" => "no such secret"}) == :ok
    end

    test "an in-use secret is an error, not a silent no-op" do
      # The regression: Docker refuses to delete a secret while a
      # service still references it. Swallowing that left the previous
      # (expired) value mounted on the next runner.
      body = %{"message" => "secret is in use by the following service: camelot-task-x"}

      assert SecretSync.delete_result(400, body) == {:error, {:delete_failed, 400, body}}
    end

    test "any other non-2xx is an error" do
      assert SecretSync.delete_result(500, %{}) == {:error, {:delete_failed, 500, %{}}}
    end
  end
end
