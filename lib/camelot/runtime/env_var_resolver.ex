defmodule Camelot.Runtime.EnvVarResolver do
  @moduledoc """
  Resolves the effective environment for a runner by
  collecting every `Camelot.Projects.EnvVar` that applies to
  an agent and merging them by scope precedence.

  Precedence, least to most specific (later wins on a key
  collision): **global → user → agent → project**. A project
  value therefore overrides an agent, user, or global value
  for the same key.

  Values are decrypted here (`Ash.Query.load(:value)`) and
  returned as a plain `%{key => value}` map ready to merge into
  `Camelot.Runtime.Runner.Spec` `env`. Values are never logged.
  """
  alias Camelot.Agents.Agent
  alias Camelot.Projects.EnvVar

  require Ash.Query

  @spec resolve(Agent.t()) :: %{String.t() => String.t()}
  def resolve(%Agent{id: agent_id, project_id: project_id, user_id: user_id}) do
    %{}
    |> merge(global_vars())
    |> merge(user_vars(user_id))
    |> merge(agent_vars(agent_id))
    |> merge(project_vars(project_id))
  end

  defp global_vars do
    EnvVar
    |> Ash.Query.filter(is_nil(project_id) and is_nil(agent_id) and is_nil(user_id))
    |> read()
  end

  defp user_vars(nil), do: []

  defp user_vars(user_id) do
    EnvVar
    |> Ash.Query.filter(user_id == ^user_id)
    |> read()
  end

  defp agent_vars(agent_id) do
    EnvVar
    |> Ash.Query.filter(agent_id == ^agent_id)
    |> read()
  end

  defp project_vars(nil), do: []

  defp project_vars(project_id) do
    EnvVar
    |> Ash.Query.filter(project_id == ^project_id)
    |> read()
  end

  defp read(query) do
    query
    |> Ash.Query.load(:value)
    |> Ash.read!(authorize?: false)
  end

  defp merge(acc, rows) do
    Enum.reduce(rows, acc, fn %EnvVar{key: key, value: value}, map ->
      Map.put(map, key, value)
    end)
  end
end
