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
end
