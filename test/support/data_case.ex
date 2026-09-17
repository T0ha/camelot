defmodule Camelot.DataCase do
  @moduledoc """
  This module defines the setup for tests requiring
  access to the application's data layer.

  You may define functions here to be used as helpers in
  your tests.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use Camelot.DataCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  alias Ecto.Adapters.SQL.Sandbox

  using do
    quote do
      use Oban.Testing, repo: Camelot.Repo

      import Camelot.DataCase
      import Ecto
      import Ecto.Changeset
      import Ecto.Query

      alias Camelot.Repo
    end
  end

  @doc """
  Looks up a seeded `Camelot.Agents.Agent` (CLI template) by slug.

  Seeded by the `add_agent_templates` migration; available
  in every sandboxed test transaction.
  """
  def agent!(slug) do
    require Ash.Query

    Camelot.Agents.Agent
    |> Ash.Query.filter(slug == ^slug)
    |> Ash.read_one!()
  end

  @doc """
  Seeds a `Camelot.Accounts.User` with a unique email. Used
  by tests that need a task creator.
  """
  def user!(attrs \\ %{}) do
    defaults = %{email: "test-#{System.unique_integer([:positive])}@example.com"}
    Ash.Seed.seed!(Camelot.Accounts.User, Map.merge(defaults, attrs))
  end

  @doc """
  Seeds a `Camelot.Github.Installation` connected to `user`.

  Needed by anything that talks to GitHub as an App installation:
  without a linked installation the requests would go out
  unauthenticated (see `Camelot.Github.Resolver.installation_id/2`).
  """
  def github_installation!(user, attrs \\ %{}) do
    defaults = %{
      installation_id: System.unique_integer([:positive]),
      account_login: "acme-org",
      account_type: :organization,
      user_id: user.id
    }

    Ash.Seed.seed!(Camelot.Github.Installation, Map.merge(defaults, attrs))
  end

  @github_app [
    app_id: "123",
    slug: "camelot-dev",
    client_id: "Iv1.abc",
    client_secret: "secret",
    private_key: Base.encode64("-----BEGIN PRIVATE KEY-----\nabc\n-----END PRIVATE KEY-----\n"),
    webhook_secret: "whsecret"
  ]

  @doc """
  Points `:github_app` at a complete dummy App config for the
  duration of the test, restoring whatever was there before.

  Anything that reads `Camelot.Github.AppConfig` branches on
  this, so tests that need the configured branch — or that
  clear it again with `put_github_app/1` to get the
  unconfigured one — should call this from `setup`. Such tests
  must be `async: false`: the config is deployment-wide.
  """
  @spec stub_github_app() :: :ok
  def stub_github_app do
    previous = Application.get_env(:camelot, :github_app)
    ExUnit.Callbacks.on_exit(fn -> put_github_app(previous) end)
    put_github_app(@github_app)
  end

  @doc "Swaps the `:github_app` config, e.g. to `[]` for unconfigured."
  @spec put_github_app(keyword() | nil) :: :ok
  def put_github_app(config) do
    Application.put_env(:camelot, :github_app, config)
  end

  setup tags do
    Camelot.DataCase.setup_sandbox(tags)
    :ok
  end

  @doc """
  Sets up the sandbox based on the test tags.
  """
  def setup_sandbox(tags) do
    pid = Sandbox.start_owner!(Camelot.Repo, shared: not tags[:async])
    on_exit(fn -> Sandbox.stop_owner(pid) end)
  end

  @doc """
  A helper that transforms changeset errors into a map of messages.

      assert {:error, changeset} = Accounts.create_user(%{password: "short"})
      assert "password is too short" in errors_on(changeset).password
      assert %{password: ["password is too short"]} = errors_on(changeset)

  """
  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
