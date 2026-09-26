defmodule Camelot.RunnerImagesTest do
  use ExUnit.Case, async: true

  alias Camelot.RunnerImages

  describe "list/0" do
    test "returns a map per stack with :stack and :image keys" do
      images = RunnerImages.list()

      assert length(images) == 6

      assert Enum.all?(images, fn entry ->
               match?(%{stack: stack, image: image} when is_binary(stack) and is_binary(image), entry)
             end)
    end

    test "includes the six stacks built by the runner-images workflow" do
      stacks = Enum.map(RunnerImages.list(), & &1.stack)

      assert Enum.sort(stacks) ==
               Enum.sort(~w(base claude codex polyglot elixir python))
    end

    test "images point at the ghcr.io/t0ha/camelot-runner-<stack>:latest tag" do
      for %{stack: stack, image: image} <- RunnerImages.list() do
        assert image == "ghcr.io/t0ha/camelot-runner-#{stack}:latest"
      end
    end
  end

  describe "sync with .github/workflows/runner-images.yml" do
    test "stack list matches the workflow's build matrix" do
      workflow_path =
        Path.join([File.cwd!(), ".github", "workflows", "runner-images.yml"])

      {:ok, workflow} = YamlElixir.read_from_file(workflow_path)
      jobs = workflow["jobs"]

      agent_cli_variants =
        get_in(jobs, ["agent_cli_variants", "strategy", "matrix", "variant"]) || []

      language_variants =
        get_in(jobs, ["language_variants", "strategy", "matrix", "variant"]) || []

      workflow_stacks = ["base" | agent_cli_variants ++ language_variants]
      catalog_stacks = Enum.map(RunnerImages.list(), & &1.stack)

      assert Enum.sort(catalog_stacks) == Enum.sort(workflow_stacks),
             "Camelot.RunnerImages has drifted from the " <>
               "runner-images.yml build matrix — update the " <>
               "hand-maintained @stacks list to match"
    end
  end

  # `runner-images/base/entrypoint.sh` writes two kinds of line, and
  # the difference matters outside the container: `[camelot] ` lines
  # are for the log collector, `[entrypoint] ` lines are shown to the
  # user. `ProvisionMonitor.entrypoint_line/1` picks the last
  # `[entrypoint] ` line and `workspace_progress/1` renders it into
  # the task page verbatim, so putting the task id and stage in one
  # of those turns a status line into "task_id=<uuid> stage=clone
  # cloning …". Pinned here because nothing else exercises the shell.
  describe "entrypoint stage logging" do
    setup do
      path = Path.join([File.cwd!(), "runner-images", "base", "entrypoint.sh"])

      %{script: File.read!(path)}
    end

    test "emits a machine-readable stage line per stage", %{script: script} do
      assert script =~ "[camelot] task_id=%s stage=%s"

      for stage <- ~w(boot clone) do
        assert script =~ "log_stage #{stage}",
               "entrypoint.sh no longer tags the #{stage} stage — " <>
                 "the collector cannot join those container logs to a task"
      end
    end

    test "keeps the task id out of the user-facing lines", %{script: script} do
      user_facing =
        script
        |> String.split("\n")
        |> Enum.filter(&String.match?(&1, ~r/^\s*log "/))

      refute Enum.any?(user_facing, &String.contains?(&1, "task_id=")),
             "a `log \"…\"` line reaches the task page as its progress " <>
               "line — use log_stage for machine-readable metadata"
    end
  end
end
