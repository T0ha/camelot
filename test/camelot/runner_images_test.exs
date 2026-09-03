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
end
