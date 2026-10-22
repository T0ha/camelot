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

  Accepts `approve:`, `merge:`, `create_issue_comment:`,
  `update_issue_comment:`, `add_issue_labels:`, `remove_issue_label:`
  and `close_issue:` replies in the client's
  `{:ok, map()} | {:error, term()}` shape; all default to success.
  Pair with `uninstall/0` in an `on_exit` callback.
  """
  @spec install(keyword()) :: :ok
  def install(opts \\ []) do
    Application.put_env(:camelot, @env_key, %{
      test_pid: self(),
      approve: Keyword.get(opts, :approve, {:ok, %{"state" => "APPROVED"}}),
      merge: Keyword.get(opts, :merge, {:ok, %{"merged" => true}}),
      create_issue_comment: Keyword.get(opts, :create_issue_comment, {:ok, %{"id" => 1}}),
      update_issue_comment: Keyword.get(opts, :update_issue_comment, {:ok, %{"id" => 1}}),
      add_issue_labels: Keyword.get(opts, :add_issue_labels, {:ok, []}),
      remove_issue_label: Keyword.get(opts, :remove_issue_label, {:ok, []}),
      close_issue: Keyword.get(opts, :close_issue, {:ok, %{"state" => "closed"}})
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

  @impl true
  def create_issue_comment(owner, repo, issue_number, body, opts) do
    reply({:create_issue_comment, owner, repo, issue_number, body, opts}, :create_issue_comment)
  end

  @impl true
  def update_issue_comment(owner, repo, comment_id, body, opts) do
    reply({:update_issue_comment, owner, repo, comment_id, body, opts}, :update_issue_comment)
  end

  @impl true
  def add_issue_labels(owner, repo, issue_number, labels, opts) do
    reply({:add_issue_labels, owner, repo, issue_number, labels, opts}, :add_issue_labels)
  end

  @impl true
  def remove_issue_label(owner, repo, issue_number, label, opts) do
    reply({:remove_issue_label, owner, repo, issue_number, label, opts}, :remove_issue_label)
  end

  @impl true
  def close_issue(owner, repo, issue_number, opts) do
    reply({:close_issue, owner, repo, issue_number, opts}, :close_issue)
  end

  defp reply(message, key) do
    config = Application.fetch_env!(:camelot, @env_key)
    send(config.test_pid, message)
    Map.fetch!(config, key)
  end
end
