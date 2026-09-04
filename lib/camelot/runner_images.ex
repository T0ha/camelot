defmodule Camelot.RunnerImages do
  @moduledoc """
  Catalog of the runner images Camelot itself builds and
  pushes to GHCR.

  This list is hand-maintained to mirror the build matrix
  in `.github/workflows/runner-images.yml` (and the
  `runner-images/` Dockerfiles it builds from) — there is
  no filesystem scan at runtime, since a release build
  doesn't ship the `runner-images/` source tree. Keep the
  two in sync by hand whenever a stack is added, renamed,
  or removed.

  This is suggestions only: `Agent.runner_image` and
  `Project.runner_image_override` remain plain unconstrained
  strings, so a fully custom image reference is always valid.
  """

  @registry "ghcr.io/t0ha/camelot-runner"
  @stacks ~w(base claude codex polyglot elixir python)

  @type entry :: %{stack: String.t(), image: String.t()}

  @spec list() :: [entry()]
  def list do
    Enum.map(@stacks, fn stack ->
      %{stack: stack, image: "#{@registry}-#{stack}:latest"}
    end)
  end
end
