defmodule Camelot.Github.Client do
  @moduledoc """
  Req-based GitHub API client for PR status polling and
  issue sync.

  Authenticates as a GitHub App installation when an
  `installation_id:` opt is given and the App is
  configured; on any failure to obtain that token (App
  not configured, no installation linked, installation
  suspended, mint failure) the request proceeds
  unauthenticated — there is no PAT to fall back to.
  """

  alias Camelot.Github.InstallationTokenCache

  require Logger

  @base_url "https://api.github.com"

  @spec get_pull_request(String.t(), String.t(), integer(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def get_pull_request(owner, repo, pr_number, opts \\ []) do
    request(:get, "/repos/#{owner}/#{repo}/pulls/#{pr_number}", opts)
  end

  @spec list_pull_request_reviews(
          String.t(),
          String.t(),
          integer(),
          keyword()
        ) :: {:ok, [map()]} | {:error, term()}
  def list_pull_request_reviews(owner, repo, pr_number, opts \\ []) do
    request(
      :get,
      "/repos/#{owner}/#{repo}/pulls/#{pr_number}/reviews",
      opts
    )
  end

  @spec list_pull_request_comments(
          String.t(),
          String.t(),
          integer(),
          keyword()
        ) :: {:ok, [map()]} | {:error, term()}
  def list_pull_request_comments(owner, repo, pr_number, opts \\ []) do
    request(
      :get,
      "/repos/#{owner}/#{repo}/issues/#{pr_number}/comments",
      opts
    )
  end

  @spec list_pull_request_commits(
          String.t(),
          String.t(),
          integer(),
          keyword()
        ) :: {:ok, [map()]} | {:error, term()}
  def list_pull_request_commits(owner, repo, pr_number, opts \\ []) do
    request(
      :get,
      "/repos/#{owner}/#{repo}/pulls/#{pr_number}/commits",
      opts
    )
  end

  @spec list_check_runs(String.t(), String.t(), String.t() | nil, keyword()) ::
          {:ok, [map()]} | {:error, term()}
  def list_check_runs(owner, repo, sha, opts \\ [])
  def list_check_runs(_owner, _repo, nil, _opts), do: {:error, :missing_sha}

  def list_check_runs(owner, repo, sha, opts) when is_binary(sha) do
    case request(
           :get,
           "/repos/#{owner}/#{repo}/commits/#{sha}/check-runs",
           opts
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
        "?state=#{state}&labels=#{labels}",
      opts
    )
  end

  @spec find_open_pr_by_head(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | :none | {:error, term()}
  def find_open_pr_by_head(owner, repo, branch, opts \\ []) do
    case request(
           :get,
           "/repos/#{owner}/#{repo}/pulls" <>
             "?state=open&head=#{owner}:#{branch}",
           opts
         ) do
      {:ok, [pr | _]} -> {:ok, pr}
      {:ok, _} -> :none
      error -> error
    end
  end

  defp request(method, path, opts) do
    url = @base_url <> path

    req_opts = maybe_add_auth([method: method, url: url], Keyword.get(opts, :installation_id))

    case Req.request(req_opts) do
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

  defp maybe_add_auth(req_opts, nil), do: req_opts

  defp maybe_add_auth(req_opts, installation_id) do
    case InstallationTokenCache.fetch(installation_id) do
      {:ok, token} ->
        Keyword.put(req_opts, :headers, [
          {"authorization", "Bearer #{token}"},
          {"accept", "application/vnd.github+json"}
        ])

      {:error, reason} ->
        Logger.warning(
          "GitHub App token unavailable for installation " <>
            "#{installation_id} (#{inspect(reason)}); " <>
            "proceeding unauthenticated"
        )

        req_opts
    end
  end
end
