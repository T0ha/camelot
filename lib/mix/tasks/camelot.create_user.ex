defmodule Mix.Tasks.Camelot.CreateUser do
  @shortdoc "Create a confirmed user account by email"

  @moduledoc """
  Creates a confirmed user account and sends them an invitation email
  so they can sign in themselves via magic link.

      mix camelot.create_user EMAIL [--role admin|user]

  Defaults to `--role admin` so the first invocation on a fresh install
  bootstraps an operator account. Subsequent users can also be added
  from `/admin/users` once an admin is signed in.

  Works in a release as:

      bin/camelot eval 'Mix.Tasks.Camelot.CreateUser.run(["user@example.com"])'
  """
  use Mix.Task

  alias Camelot.Accounts.User

  @valid_roles ~w(admin user)
  @switches [role: :string]

  @impl Mix.Task
  @spec run([String.t()]) :: :ok
  def run(argv) do
    {:ok, _} = Application.ensure_all_started(:camelot)

    {opts, args, _} = OptionParser.parse(argv, strict: @switches)
    email = List.first(args) || raise(ArgumentError, usage())
    role = parse_role(opts[:role] || "admin")

    user =
      User
      |> Ash.Changeset.for_create(:create_user, %{email: email, role: role}, authorize?: false)
      |> Ash.create!(authorize?: false)

    IO.puts("Created #{role} #{user.email} (#{user.id})")
    :ok
  end

  defp parse_role(role) when role in @valid_roles, do: String.to_existing_atom(role)
  defp parse_role(other), do: raise(ArgumentError, "Invalid --role: #{other}. Use admin or user.")

  defp usage, do: "Usage: mix camelot.create_user EMAIL [--role admin|user]"
end
