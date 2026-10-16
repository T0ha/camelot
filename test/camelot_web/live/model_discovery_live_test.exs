defmodule CamelotWeb.ModelDiscoveryLiveTest do
  # async: false — the model API stub is installed in application env,
  # which is deployment-wide.
  use CamelotWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Camelot.Accounts.Credential
  alias Camelot.Accounts.User
  alias Camelot.Agents.Agent
  alias Camelot.Board.Task
  alias Camelot.Projects.Project
  alias Camelot.Support.StubModelApi

  require Ash.Query

  @anthropic_url "https://api.anthropic.com/v1/models"
  @openai_url "https://api.openai.com/v1/models"

  setup do
    on_exit(&StubModelApi.uninstall/0)

    :ok
  end

  defp listing(ids) do
    {:ok, %{"data" => Enum.map(ids, &%{"id" => &1, "object" => "model"})}}
  end

  defp credential!(user, kind, value) do
    Ash.create!(Credential, %{kind: kind, value: value, user_id: user.id})
  end

  describe "New Task model picker" do
    setup :register_and_log_in_user

    setup %{user: user} do
      credential!(user, :claude_api_key, "sk-ant-api03-board-#{user.id}")
      credential!(user, :openai_api_key, "sk-proj-board-#{user.id}")

      project =
        Ash.create!(
          Project,
          %{name: "board-#{System.unique_integer([:positive])}", path: "/tmp/board"},
          actor: user
        )

      %{project: project}
    end

    test "offers what the provider listed for this user", %{conn: conn} do
      StubModelApi.install(reply: listing(["claude-opus-5-5"]))

      {:ok, view, _html} = live(conn, ~p"/")

      render_click(view, "open_new_task")

      html =
        view
        |> form("#new-task-form", %{"task" => %{"agent_id" => agent!("claude_code").id}})
        |> render_change()

      assert html =~ ~s(value="claude-opus-5-5")
      assert html =~ "Claude Opus 5 5"
      assert_receive {:list_models, @anthropic_url, _headers}
    end

    # The pinned column is the offline fallback, so a provider that is
    # down leaves the dropdown exactly as it was before this feature.
    test "a failing probe leaves the pinned options in place", %{conn: conn} do
      StubModelApi.install(reply: {:error, %Req.TransportError{reason: :timeout}})

      {:ok, view, _html} = live(conn, ~p"/")

      render_click(view, "open_new_task")

      html =
        view
        |> form("#new-task-form", %{"task" => %{"agent_id" => agent!("claude_code").id}})
        |> render_change()

      for model <- agent!("claude_code").available_models do
        assert html =~ ~s(value="#{model}")
      end
    end

    test "re-resolves when the picked agent changes", %{conn: conn} do
      StubModelApi.install(
        replies: %{
          @anthropic_url => listing(["claude-opus-5-5"]),
          @openai_url => listing(["gpt-5.7-nova"])
        }
      )

      {:ok, view, _html} = live(conn, ~p"/")

      render_click(view, "open_new_task")

      html =
        view
        |> form("#new-task-form", %{"task" => %{"agent_id" => agent!("claude_code").id}})
        |> render_change()

      assert html =~ ~s(value="claude-opus-5-5")

      html =
        view
        |> form("#new-task-form", %{"task" => %{"agent_id" => agent!("codex").id}})
        |> render_change()

      assert html =~ ~s(value="gpt-5.7-nova")
      refute html =~ ~s(value="claude-opus-5-5")
    end

    test "a discovered-only model can be created", %{conn: conn, project: project} do
      StubModelApi.install(reply: listing(["claude-opus-5-5"]))

      title = "discovered-#{System.unique_integer([:positive])}"

      {:ok, view, _html} = live(conn, ~p"/")

      render_click(view, "open_new_task")

      view
      |> form("#new-task-form", %{
        "task" => %{
          "title" => title,
          "project_id" => project.id,
          "agent_id" => agent!("claude_code").id
        }
      })
      |> render_change()

      view
      |> form("#new-task-form", %{
        "task" => %{
          "title" => title,
          "project_id" => project.id,
          "agent_id" => agent!("claude_code").id,
          "next_model" => "claude-opus-5-5"
        }
      })
      |> render_submit()

      task = Task |> Ash.Query.filter(title == ^title) |> Ash.read_one!()
      assert task.next_model == "claude-opus-5-5"
    end
  end

  describe "task page model picker" do
    setup :register_and_log_in_admin

    # The runner mounts the *creator's* key, so it is their
    # entitlements that decide whether a run succeeds — even when
    # somebody else is looking at the task.
    test "resolves with the creator's credential, not the viewer's", %{conn: conn} do
      creator =
        Ash.Seed.seed!(User, %{email: "creator-#{System.unique_integer([:positive])}@example.com"})

      credential!(creator, :claude_api_key, "sk-ant-api03-creator")

      project =
        Ash.create!(Project, %{name: "tl-#{System.unique_integer([:positive])}", path: "/tmp/tl"})

      task =
        Ash.create!(Task, %{
          title: "Creator's task",
          project_id: project.id,
          creator_id: creator.id,
          agent_id: agent!("claude_code").id
        })

      StubModelApi.install(reply: listing(["claude-opus-5-5"]))

      {:ok, _view, html} = live(conn, ~p"/tasks/#{task.id}")

      assert html =~ ~s(value="claude-opus-5-5")
      assert_receive {:list_models, @anthropic_url, headers}
      assert {"x-api-key", "sk-ant-api03-creator"} in headers
    end
  end

  describe "/agents model check" do
    setup :register_and_log_in_admin

    setup %{user: user} do
      credential!(user, :claude_api_key, "sk-ant-api03-admin-#{user.id}")

      :ok
    end

    test "edits the probe config and keeps it across a reload", %{conn: conn} do
      probe = %{
        "strategy" => "http_models_endpoint",
        "url" => "https://example.test/v1/models",
        "auth" => "bearer",
        "credential_kind" => "claude_api_key",
        "include" => "^claude-"
      }

      {:ok, view, _html} = live(conn, ~p"/agents/#{agent!("claude_code").id}/edit")

      view
      |> form("#agent-form", %{"models_probe" => Jason.encode!(probe)})
      |> render_submit()

      assert agent!("claude_code").models_probe == probe
    end

    test "clearing the probe config disables discovery", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/agents/#{agent!("claude_code").id}/edit")

      view
      |> form("#agent-form", %{"models_probe" => "{}"})
      |> render_submit()

      assert agent!("claude_code").models_probe == nil
    end

    test "Check models lists what the provider returned", %{conn: conn} do
      StubModelApi.install(reply: listing(["claude-opus-5-5"]))

      {:ok, view, _html} = live(conn, ~p"/agents")

      html = render_click(view, "check_models", %{"id" => agent!("claude_code").id})

      assert html =~ "Models discovered for Claude Code"
      assert html =~ "claude-opus-5-5"
    end

    test "Check models explains a probe that cannot run", %{conn: conn} do
      agent =
        Ash.create!(Agent, %{
          slug: "unprobed-#{System.unique_integer([:positive])}",
          name: "Unprobed",
          executable: "unprobed"
        })

      {:ok, view, _html} = live(conn, ~p"/agents")

      html = render_click(view, "check_models", %{"id" => agent.id})

      assert html =~ "No usable model discovery probe"
    end

    # Nothing ever writes `available_models` automatically — pinning is
    # an explicit second click, so a check cannot clobber an admin's
    # hand-maintained fallback.
    test "Pin these writes the discovered ids to available_models", %{conn: conn} do
      StubModelApi.install(reply: listing(["claude-opus-5-5"]))

      {:ok, view, _html} = live(conn, ~p"/agents")

      render_click(view, "check_models", %{"id" => agent!("claude_code").id})

      refute "claude-opus-5-5" in agent!("claude_code").available_models

      view |> element("button", "Pin these") |> render_click()

      assert agent!("claude_code").available_models == ["claude-opus-5-5"]
    end
  end
end
