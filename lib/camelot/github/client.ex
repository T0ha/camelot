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
  @max_pages 20

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

  @spec list_pull_request_review_comments(
          String.t(),
          String.t(),
          integer(),
          keyword()
        ) :: {:ok, [map()]} | {:error, term()}
  def list_pull_request_review_comments(owner, repo, pr_number, opts \\ []) do
    request(
      :get,
      "/repos/#{owner}/#{repo}/pulls/#{pr_number}/comments",
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

  @doc """
  Lists repositories accessible to a GitHub App
  installation, for autocomplete-style pickers.

  Follows the `Link: rel="next"` pagination header until
  exhausted (capped at `@max_pages` to bound worst-case
  latency/memory for a pathologically large installation),
  so large orgs aren't silently truncated to the first page.
  """
  @spec list_installation_repositories(integer(), keyword()) ::
          {:ok, [map()]} | {:error, term()}
  def list_installation_repositories(installation_id, opts \\ []) do
    opts = Keyword.put(opts, :installation_id, installation_id)

    fetch_installation_repositories_page(
      "/installation/repositories?per_page=100",
      opts,
      [],
      @max_pages
    )
  end

  defp fetch_installation_repositories_page(_url, _opts, acc, 0), do: {:ok, acc}

  defp fetch_installation_repositories_page(url, opts, acc, pages_left) do
    case request_with_headers(:get, url, opts) do
      {:ok, %{"repositories" => repos}, headers} when is_list(repos) ->
        acc = acc ++ Enum.map(repos, &normalize_repository/1)

        case next_link(headers) do
          nil -> {:ok, acc}
          next_url -> fetch_installation_repositories_page(next_url, opts, acc, pages_left - 1)
        end

      {:ok, _other, _headers} ->
        {:ok, acc}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp next_link(headers) do
    headers
    |> Map.get("link", [])
    |> List.first()
    |> parse_next_link()
  end

  defp parse_next_link(nil), do: nil

  defp parse_next_link(link_header) do
    link_header
    |> String.split(",")
    |> Enum.find_value(fn part ->
      case Regex.run(~r/<([^>]+)>;\s*rel="next"/, part) do
        [_, url] -> url
        nil -> nil
      end
    end)
  end

  defp normalize_repository(repo) do
    %{
      owner: get_in(repo, ["owner", "login"]),
      repo: repo["name"],
      full_name: repo["full_name"],
      html_url: repo["html_url"]
    }
  end

  defp request(method, path, opts) do
    case request_with_headers(method, path, opts) do
      {:ok, body, _headers} -> {:ok, body}
      {:error, reason} -> {:error, reason}
    end
  end

  defp request_with_headers(method, url_or_path, opts) do
    url = full_url(url_or_path)

    req_opts = maybe_add_auth([method: method, url: url], Keyword.get(opts, :installation_id))

    case Req.request(req_opts) do
      {:ok, %Req.Response{status: status, body: body, headers: headers}}
      when status in 200..299 ->
        {:ok, body, headers}

      {:ok, %Req.Response{status: status, body: body}} ->
        Logger.warning("GitHub API #{status}: #{inspect(body)}")

        {:error, {:http_error, status, body}}

      {:error, reason} ->
        Logger.error("GitHub API request failed: #{inspect(reason)}")

        {:error, reason}
    end
  end

  defp full_url("https://" <> _rest = url), do: url
  defp full_url(path), do: @base_url <> path

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
