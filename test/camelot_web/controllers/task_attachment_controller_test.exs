defmodule CamelotWeb.TaskAttachmentControllerTest do
  use CamelotWeb.ConnCase, async: false

  alias Camelot.Accounts.User
  alias Camelot.Board.AttachmentStore
  alias Camelot.Board.Task
  alias Camelot.Board.TaskAttachment
  alias Camelot.Projects.Project
  alias CamelotWeb.TaskAttachmentController

  setup do
    base_dir = Path.join(System.tmp_dir!(), "camelot-attachments-test-#{System.unique_integer([:positive])}")
    previous = Application.get_env(:camelot, :attachments_dir)
    Application.put_env(:camelot, :attachments_dir, base_dir)

    on_exit(fn ->
      File.rm_rf(base_dir)

      if previous do
        Application.put_env(:camelot, :attachments_dir, previous)
      else
        Application.delete_env(:camelot, :attachments_dir)
      end
    end)

    %{base_dir: base_dir}
  end

  setup :register_and_log_in_user

  setup %{user: user, base_dir: base_dir} do
    {:ok, project} =
      Ash.create(Project, %{name: "attach-ctrl-#{System.unique_integer([:positive])}", path: "/tmp/actrl"}, actor: user)

    {:ok, task} =
      Ash.create(Task, %{
        title: "Ctrl task",
        project_id: project.id,
        creator_id: user.id,
        agent_id: agent!("claude_code").id
      })

    tmp_path = Path.join(base_dir, "src.txt")
    File.mkdir_p!(base_dir)
    File.write!(tmp_path, "download me")

    {:ok, storage_key, byte_size} = AttachmentStore.put(task.id, tmp_path, "notes.txt")

    {:ok, attachment} =
      Ash.create(TaskAttachment, %{
        filename: "notes.txt",
        content_type: "text/plain",
        byte_size: byte_size,
        storage_key: storage_key,
        task_id: task.id
      })

    %{project: project, task: task, attachment: attachment}
  end

  describe "download/2 — session auth" do
    test "a project member downloads the file", %{conn: conn, attachment: attachment} do
      conn = get(conn, ~p"/attachments/#{attachment.id}/download")

      assert conn.status == 200
      assert response(conn, 200) == "download me"
      assert get_resp_header(conn, "content-type") == ["text/plain"]
    end

    test "a non-member gets a 404", %{attachment: attachment} do
      other = Ash.Seed.seed!(User, %{email: "other-#{System.unique_integer()}@example.com"})
      {:ok, token, _claims} = AshAuthentication.Jwt.token_for_user(other)
      other = %{other | __metadata__: Map.put(other.__metadata__, :token, token)}

      %{conn: conn} = log_in_user(Phoenix.ConnTest.build_conn(), other)

      conn = get(conn, ~p"/attachments/#{attachment.id}/download")
      assert conn.status == 404
    end

    test "an admin downloads without membership", %{attachment: attachment} do
      %{conn: conn} = register_and_log_in_admin(%{conn: Phoenix.ConnTest.build_conn()})

      conn = get(conn, ~p"/attachments/#{attachment.id}/download")
      assert conn.status == 200
    end

    test "an unknown id gets a 404", %{conn: conn} do
      conn = get(conn, ~p"/attachments/#{Ecto.UUID.generate()}/download")
      assert conn.status == 404
    end
  end

  describe "download/2 — signed token auth" do
    test "a valid token works without a session", %{attachment: attachment} do
      token = TaskAttachmentController.sign_token(attachment.id)

      conn =
        Phoenix.ConnTest.build_conn()
        |> Plug.Test.init_test_session(%{})
        |> get(~p"/attachments/#{attachment.id}/download?token=#{token}")

      assert conn.status == 200
      assert response(conn, 200) == "download me"
    end

    test "a token signed for a different attachment id is rejected", %{attachment: attachment} do
      token = TaskAttachmentController.sign_token(Ecto.UUID.generate())

      conn =
        Phoenix.ConnTest.build_conn()
        |> Plug.Test.init_test_session(%{})
        |> get(~p"/attachments/#{attachment.id}/download?token=#{token}")

      assert conn.status == 404
    end
  end

  describe "download/2 — S3 backend redirects" do
    setup do
      previous_store = Application.get_env(:camelot, :attachment_store)
      previous_s3 = Application.get_env(:camelot, :attachment_store_s3)

      Application.put_env(:camelot, :attachment_store, AttachmentStore.S3)

      Application.put_env(:camelot, :attachment_store_s3,
        endpoint: "https://compat.objectstorage.example.com",
        bucket: "camelot-attachments",
        access_key_id: "test-key",
        secret_access_key: "test-secret",
        region: "us-ashburn-1"
      )

      on_exit(fn ->
        Application.put_env(:camelot, :attachment_store, previous_store)
        Application.put_env(:camelot, :attachment_store_s3, previous_s3)
      end)

      :ok
    end

    test "302s to a presigned URL", %{conn: conn, attachment: attachment} do
      conn = get(conn, ~p"/attachments/#{attachment.id}/download")

      assert conn.status == 302
      [location] = get_resp_header(conn, "location")
      assert location =~ "https://compat.objectstorage.example.com/camelot-attachments/"
      assert location =~ "X-Amz-Algorithm=AWS4-HMAC-SHA256"
    end
  end
end
