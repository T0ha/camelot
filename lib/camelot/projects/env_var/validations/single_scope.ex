defmodule Camelot.Projects.EnvVar.Validations.SingleScope do
  @moduledoc """
  Ensures an `EnvVar` attaches to at most one scope.

  A row may set at most one of `project_id`, `agent_id`, or
  `user_id`. Setting none makes it a global default; setting
  more than one is ambiguous and rejected. The scope decides
  precedence at resolve time (project > agent > user > global).
  """
  use Ash.Resource.Validation

  @scope_fields [:project_id, :agent_id, :user_id]

  @impl true
  def validate(changeset, _opts, _context) do
    set =
      Enum.count(@scope_fields, fn field ->
        not is_nil(Ash.Changeset.get_attribute(changeset, field))
      end)

    case set do
      n when n <= 1 ->
        :ok

      _ ->
        {:error, field: :base, message: "must belong to at most one scope (project, agent, or user)"}
    end
  end

  @impl true
  def describe(_opts) do
    [message: "must belong to at most one scope", vars: []]
  end
end
