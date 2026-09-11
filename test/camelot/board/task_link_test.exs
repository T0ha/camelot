defmodule Camelot.Board.TaskLinkTest do
  use Camelot.DataCase, async: true

  alias Camelot.Accounts.User
  alias Camelot.Board.Task
  alias Camelot.Board.TaskLink
  alias Camelot.Projects.Project

  setup do
    {:ok, project_a} = Ash.create(Project, %{name: "project-a", path: "/tmp/project-a"})
    {:ok, project_b} = Ash.create(Project, %{name: "project-b", path: "/tmp/project-b"})

    {:ok, hashed} = AshAuthentication.BcryptProvider.hash("Hello world!123")

    user =
      Ash.Seed.seed!(User, %{
        email: "task-link-test@example.com",
        hashed_password: hashed
      })

    agent = agent!("claude_code")

    %{project_a: project_a, project_b: project_b, user: user, agent: agent}
  end

  defp create_task(project, ctx, attrs \\ %{}) do
    defaults = %{
      title: "task-#{System.unique_integer([:positive])}",
      project_id: project.id,
      creator_id: ctx.user.id,
      agent_id: ctx.agent.id
    }

    {:ok, task} = Ash.create(Task, Map.merge(defaults, attrs))
    task
  end

  defp create_link(source, target, link_type) do
    Ash.create(TaskLink, %{
      source_task_id: source.id,
      target_task_id: target.id,
      link_type: link_type
    })
  end

  describe "create" do
    test "creates a :blocks link", ctx do
      a = create_task(ctx.project_a, ctx)
      b = create_task(ctx.project_a, ctx)

      assert {:ok, link} = create_link(a, b, :blocks)
      assert link.source_task_id == a.id
      assert link.target_task_id == b.id
      assert link.link_type == :blocks
    end

    test "creates a :parent_of link", ctx do
      parent = create_task(ctx.project_a, ctx)
      child = create_task(ctx.project_a, ctx)

      assert {:ok, link} = create_link(parent, child, :parent_of)
      assert link.link_type == :parent_of
    end

    test "creates a :relates_to link", ctx do
      a = create_task(ctx.project_a, ctx)
      b = create_task(ctx.project_a, ctx)

      assert {:ok, link} = create_link(a, b, :relates_to)
      assert link.link_type == :relates_to
    end

    test "a cross-project link succeeds", ctx do
      a = create_task(ctx.project_a, ctx)
      b = create_task(ctx.project_b, ctx)

      assert {:ok, _link} = create_link(a, b, :blocks)
    end

    test ":relates_to is canonicalized so the smaller id is always source", ctx do
      a = create_task(ctx.project_a, ctx)
      b = create_task(ctx.project_a, ctx)

      assert {:ok, link} = create_link(a, b, :relates_to)
      assert link.source_task_id == Enum.min([a.id, b.id])
      assert link.target_task_id == Enum.max([a.id, b.id])
    end
  end

  describe "validations" do
    test "rejects a self-link", ctx do
      a = create_task(ctx.project_a, ctx)

      assert {:error, _error} = create_link(a, a, :blocks)
    end

    test "rejects an exact duplicate link", ctx do
      a = create_task(ctx.project_a, ctx)
      b = create_task(ctx.project_a, ctx)

      assert {:ok, _link} = create_link(a, b, :blocks)
      assert {:error, _error} = create_link(a, b, :blocks)
    end

    test "rejects a :relates_to duplicate submitted in the opposite direction", ctx do
      a = create_task(ctx.project_a, ctx)
      b = create_task(ctx.project_a, ctx)

      assert {:ok, _link} = create_link(a, b, :relates_to)
      assert {:error, _error} = create_link(b, a, :relates_to)
    end

    test "rejects a second parent for the same task", ctx do
      parent_1 = create_task(ctx.project_a, ctx)
      parent_2 = create_task(ctx.project_a, ctx)
      child = create_task(ctx.project_a, ctx)

      assert {:ok, _link} = create_link(parent_1, child, :parent_of)
      assert {:error, _error} = create_link(parent_2, child, :parent_of)
    end
  end

  describe "cycle rejection" do
    test "rejects a direct 2-node :blocks cycle", ctx do
      a = create_task(ctx.project_a, ctx)
      b = create_task(ctx.project_a, ctx)

      assert {:ok, _link} = create_link(a, b, :blocks)
      assert {:error, _error} = create_link(b, a, :blocks)
    end

    test "rejects a 3-node :blocks cycle", ctx do
      a = create_task(ctx.project_a, ctx)
      b = create_task(ctx.project_a, ctx)
      c = create_task(ctx.project_a, ctx)

      assert {:ok, _link} = create_link(a, b, :blocks)
      assert {:ok, _link} = create_link(b, c, :blocks)
      assert {:error, _error} = create_link(c, a, :blocks)
    end

    # Mixed-type cycle: A is the parent of B (so A waits on B — the
    # `blocked_by_subtasks?` aggregate), and separately A blocks B (so
    # B waits on A — the `blocked_by_blockers?` aggregate). Combined
    # this is a direct 2-node deadlock in the wait-for graph, exactly
    # the "dangerous mixed case" the design doc calls out, though its
    # own worked example (`A parent_of B` + `B blocks A`) does not
    # actually cycle under the doc's own edge mapping — both those
    # links point the same way (A waits on B twice, redundantly, not
    # a cycle). See the PR description for the full note.
    test "rejects a mixed :parent_of + :blocks cycle", ctx do
      a = create_task(ctx.project_a, ctx)
      b = create_task(ctx.project_a, ctx)

      assert {:ok, _link} = create_link(a, b, :parent_of)
      assert {:error, _error} = create_link(a, b, :blocks)
    end

    test "a non-cyclic mixed combination succeeds", ctx do
      a = create_task(ctx.project_a, ctx)
      b = create_task(ctx.project_a, ctx)

      assert {:ok, _link} = create_link(a, b, :parent_of)
      assert {:ok, _link} = create_link(b, a, :blocks)
    end

    test ":relates_to never participates in a cycle check", ctx do
      a = create_task(ctx.project_a, ctx)
      b = create_task(ctx.project_a, ctx)

      assert {:ok, _link} = create_link(a, b, :blocks)
      assert {:ok, _link} = create_link(b, a, :relates_to)
    end
  end

  describe "cascade delete" do
    test "deleting a task destroys its links", ctx do
      a = create_task(ctx.project_a, ctx)
      b = create_task(ctx.project_a, ctx)

      {:ok, link} = create_link(a, b, :blocks)

      Ash.destroy!(a)

      assert {:error, _error} = Ash.get(TaskLink, link.id)
    end
  end
end
