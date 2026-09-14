defmodule Camelot.Support.StubPullRequestApi do
  @moduledoc """
  Test stub for `Camelot.Github.PullRequestApi`.

  `install/1` swaps the configured implementation for this module
  and records the canned replies plus the test pid in application
  env — not the process dictionary — because the code under test
  often runs in another process (a LiveView, for instance).

  Every call messages the test process, so assertions can check
  exactly what would have been sent to GitHub.
  """

  @behaviour Camelot.Github.PullRequestApi

  @env_key :stub_pull_request_api

  @doc """
  Installs the stub, optionally overriding what each call returns.

  Accepts `approve:` and `merge:` replies in the client's
  `{:ok, map()} | {:error, term()}` shape; both default to success.
  Pair with `uninstall/0` in an `on_exit` callback.
  """
  @spec install(keyword()) :: :ok
  def install(opts \\ []) do
    Application.put_env(:camelot, @env_key, %{
      test_pid: self(),
      approve: Keyword.get(opts, :approve, {:ok, %{"state" => "APPROVED"}}),
      merge: Keyword.get(opts, :merge, {:ok, %{"merged" => true}})
    })

    Application.put_env(:camelot, :github_pull_request_api, __MODULE__)
  end

  @doc "Restores the real GitHub pull request API implementation."
  @spec uninstall() :: :ok
  def uninstall do
    Application.delete_env(:camelot, :github_pull_request_api)
    Application.delete_env(:camelot, @env_key)
  end

  @impl true
  def approve_pull_request(owner, repo, pr_number, opts) do
    reply({:approve_pull_request, owner, repo, pr_number, opts}, :approve)
  end

  @impl true
  def merge_pull_request(owner, repo, pr_number, opts) do
    reply({:merge_pull_request, owner, repo, pr_number, opts}, :merge)
  end

  defp reply(message, key) do
    config = Application.fetch_env!(:camelot, @env_key)
    send(config.test_pid, message)
    Map.fetch!(config, key)
  end
end
