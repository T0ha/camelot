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
