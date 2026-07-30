defmodule Camelot.Agents.CredentialKinds do
  @moduledoc """
  Array-of-atom Ash type for `AgentTemplate.required_credential_kinds`.

  `{:array, :atom}` fails to load the whole row if any stored
  element isn't a currently-known atom — retiring a credential kind
  (removing its atom literal from the app entirely, e.g.
  `github_pat`/`github_oauth` in PR #75) permanently breaks loading
  any template row still carrying it in Postgres, which silently
  stalls task dispatch. Drop unknown/legacy entries on load instead
  of failing, so a template stays loadable even if a cleanup
  migration hasn't run (or missed a row).
  """
  use Ash.Type

  alias Camelot.Accounts.Credential

  @impl true
  def storage_type(_), do: {:array, :string}

  @impl true
  def cast_input(nil, _), do: {:ok, nil}

  def cast_input(value, _) when is_list(value) do
    if Enum.all?(value, &(&1 in Credential.valid_kinds())) do
      {:ok, value}
    else
      :error
    end
  end

  def cast_input(_, _), do: :error

  @impl true
  def cast_stored(nil, _), do: {:ok, nil}

  def cast_stored(value, _) when is_list(value) do
    known = Enum.map(Credential.valid_kinds(), &Atom.to_string/1)

    atoms =
      value
      |> Enum.filter(&(&1 in known))
      |> Enum.map(&String.to_existing_atom/1)

    {:ok, atoms}
  end

  def cast_stored(_, _), do: :error

  @impl true
  def dump_to_native(nil, _), do: {:ok, nil}

  def dump_to_native(value, _) when is_list(value) do
    {:ok, Enum.map(value, &to_string/1)}
  end

  def dump_to_native(_, _), do: :error

  @impl true
  def matches_type?(value, _) when is_list(value), do: Enum.all?(value, &is_atom/1)
  def matches_type?(_, _), do: false
end
