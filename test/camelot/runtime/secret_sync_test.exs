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
end
