defmodule Camelot.Projects.Project.Validations.RepoRequiredForCloudRunner do
  @moduledoc """
  Requires `github_repo_url` on project creation when the configured
  runner backend clones from a hosted repo (`DockerEngine`, `Swarm`)
  instead of running in place via `LocalPort`.

  Scoped to `:create` only, not `:update` or `:archive` — a project
  that predates this rule and still lacks a repo URL under a cloud
  backend should stay editable.
  """
  use Ash.Resource.Validation

  alias Camelot.Runtime.Runner

  @message "is required when the runner backend clones from a hosted repo instead of using a local path"

  @impl true
  def validate(changeset, _opts, _context) do
    with true <- Runner.cloud?(),
         true <- blank?(Ash.Changeset.get_attribute(changeset, :github_repo_url)) do
      {:error, field: :github_repo_url, message: @message}
    else
      _ -> :ok
    end
  end

  defp blank?(nil), do: true
  defp blank?(url), do: String.trim(url) == ""

  @impl true
  def describe(_opts) do
    [message: @message, vars: []]
  end
end
