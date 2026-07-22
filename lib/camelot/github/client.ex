defmodule Camelot.Github.Client do
  @moduledoc """
  Req-based GitHub API client for PR status polling.
  """

  require Logger

  @base_url "https://api.github.com"

  @spec get_pull_request(String.t(), String.t(), integer()) ::
          {:ok, map()} | {:error, term()}
  def get_pull_request(owner, repo, pr_number) do
    request(:get, "/repos/#{owner}/#{repo}/pulls/#{pr_number}")
  end

  @spec list_pull_request_reviews(
          String.t(),
          String.t(),
          integer()
        ) :: {:ok, [map()]} | {:error, term()}
  def list_pull_request_reviews(owner, repo, pr_number) do
    request(
      :get,
      "/repos/#{owner}/#{repo}/pulls/#{pr_number}/reviews"
    )
  end

  @spec list_pull_request_comments(
          String.t(),
          String.t(),
          integer()
        ) :: {:ok, [map()]} | {:error, term()}
  def list_pull_request_comments(owner, repo, pr_number) do
    request(
      :get,
      "/repos/#{owner}/#{repo}/issues/#{pr_number}/comments"
    )
  end

  @spec list_pull_request_commits(
          String.t(),
          String.t(),
          integer()
        ) :: {:ok, [map()]} | {:error, term()}
  def list_pull_request_commits(owner, repo, pr_number) do
    request(
      :get,
      "/repos/#{owner}/#{repo}/pulls/#{pr_number}/commits"
    )
  end

  @spec list_check_runs(String.t(), String.t(), String.t() | nil) ::
          {:ok, [map()]} | {:error, term()}
  def list_check_runs(_owner, _repo, nil), do: {:error, :missing_sha}

  def list_check_runs(owner, repo, sha) when is_binary(sha) do
    case request(
           :get,
           "/repos/#{owner}/#{repo}/commits/#{sha}/check-runs"
         ) do
      {:ok, %{"check_runs" => runs}} when is_list(runs) -> {:ok, runs}
      {:ok, _other} -> {:ok, []}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec list_issues(String.t(), String.t(), keyword()) ::
          {:ok, [map()]} | {:error, term()}
  def list_issues(owner, repo, opts \\ []) do
    labels = Keyword.get(opts, :labels, "")
    state = Keyword.get(opts, :state, "open")

    request(
      :get,
      "/repos/#{owner}/#{repo}/issues" <>
        "?state=#{state}&labels=#{labels}"
    )
  end

  @spec find_open_pr_by_head(String.t(), String.t(), String.t()) ::
          {:ok, map()} | :none | {:error, term()}
  def find_open_pr_by_head(owner, repo, branch) do
    case request(
           :get,
           "/repos/#{owner}/#{repo}/pulls" <>
             "?state=open&head=#{owner}:#{branch}"
         ) do
      {:ok, [pr | _]} -> {:ok, pr}
      {:ok, _} -> :none
      error -> error
    end
  end

  defp request(method, path) do
    url = @base_url <> path

    opts = maybe_add_auth(method: method, url: url)

    case Req.request(opts) do
      {:ok, %Req.Response{status: status, body: body}}
      when status in 200..299 ->
        {:ok, body}

      {:ok, %Req.Response{status: status, body: body}} ->
        Logger.warning("GitHub API #{status}: #{inspect(body)}")

        {:error, {:http_error, status, body}}

      {:error, reason} ->
        Logger.error("GitHub API request failed: #{inspect(reason)}")

        {:error, reason}
    end
  end

  defp maybe_add_auth(opts) do
    case Application.get_env(:camelot, :github_token) do
      nil ->
        opts

      token ->
        Keyword.put(opts, :headers, [
          {"authorization", "Bearer #{token}"},
          {"accept", "application/vnd.github+json"}
        ])
    end
  end
end
