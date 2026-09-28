defmodule CamelotWeb.RequestContextTest do
  @moduledoc """
  A request describes itself and nothing else.

  `user_id` / `project_id` / `task_id` reach the JSON logs through
  `Logger.metadata/1`, and `$current_url` reaches PostHog through
  `PostHog.set_context/1` — both of which write into the *process*
  dictionary. A LiveView's connected process is its own, but its dead
  render runs in the connection process, and Bandit keeps one process
  per TCP connection, looping over every keep-alive request on it
  (`Bandit.HTTP1.Handler.handle_data/3`).

  Nothing in Plug, Phoenix or LiveView clears either between those
  requests, and `PostHog.Context` has no delete at all — it only
  merges. Without a reset, the page a browser last loaded tags every
  later request it makes over the same connection.
  """
  use CamelotWeb.ConnCase, async: true

  alias Camelot.Board.Task
  alias Camelot.Projects.Project

  require Logger

  setup :register_and_log_in_user

  setup %{user: user} do
    {:ok, project} =
      Ash.create(
        Project,
        %{name: "req-context-proj", path: "/tmp/req-context-proj"},
        actor: user
      )

    {:ok, task} =
      Ash.create(Task, %{
        title: "Request context task",
        description: "A task whose id must not outlive its request",
        project_id: project.id,
        creator_id: user.id,
        agent_id: agent!("claude_code").id
      })

    %{task: task, project: project}
  end

  describe "log metadata" do
    test "a rendered page tags the request it was rendered for", %{conn: conn, task: task} do
      get(conn, ~p"/tasks/#{task.id}")

      metadata = Logger.metadata()

      assert metadata[:task_id] == task.id
      assert metadata[:project_id] == task.project_id
      assert metadata[:user_id] == task.creator_id
    end

    test "the next request on the same connection does not inherit them", %{
      conn: conn,
      task: task
    } do
      get(conn, ~p"/tasks/#{task.id}")

      # Same process, as a keep-alive connection would be.
      get(build_conn(), ~p"/sign-in")

      metadata = Logger.metadata()

      refute metadata[:task_id]
      refute metadata[:project_id]
      refute metadata[:user_id]
    end

    # `distinct_id` is what PostHog's error-tracking handler reads to
    # decide whose crash it is, so a stale one files the next
    # visitor's error under the last person to use the connection.
    test "the next request on the same connection is not attributed to the last person", %{
      conn: conn,
      task: task
    } do
      get(conn, ~p"/tasks/#{task.id}")
      assert Logger.metadata()[:distinct_id] == task.creator_id

      get(build_conn(), ~p"/sign-in")

      refute Logger.metadata()[:distinct_id]
    end

    test "signing out does not leave the signed-in user on later requests", %{
      conn: conn,
      user: user
    } do
      get(conn, ~p"/projects")
      assert Logger.metadata()[:user_id] == user.id

      get(build_conn(), ~p"/sign-in")

      refute Logger.metadata()[:user_id]
    end
  end

  describe "posthog context" do
    test "a capture reports the page the request is for", %{conn: conn, task: task} do
      get(conn, ~p"/tasks/#{task.id}")

      assert current_url() =~ "/tasks/#{task.id}"
    end

    # `CamelotWeb.LiveUserAuth` writes `$current_url` into the
    # instance scope, which `PostHog.Context.get/2` merges *after* the
    # `:all` scope `PostHog.Integrations.Plug` sets — so the stale
    # value wins over this request's own until it is cleared.
    test "the next request on the same connection reports its own page", %{
      conn: conn,
      task: task
    } do
      get(conn, ~p"/tasks/#{task.id}")
      get(build_conn(), ~p"/sign-in")

      assert current_url() =~ "/sign-in"
      refute current_url() =~ task.id
    end
  end

  defp current_url do
    "any_event" |> PostHog.get_event_context() |> Map.get(:"$current_url", "")
  end
end
