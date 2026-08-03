defmodule Camelot.Github.IssueAttachments do
  @moduledoc """
  Imports images/files embedded in a GitHub issue body as
  `Camelot.Board.TaskAttachment`s, so a task auto-created from a
  labelled issue (`Camelot.Projects.Changes.SyncGithubIssues`) carries
  the same attachments the issue does.
  """

  alias Camelot.Board.AttachmentStore
  alias Camelot.Board.Task
  alias Camelot.Board.TaskAttachment

  require Logger

  @markdown_image ~r/!\[[^\]]*\]\((https?:\/\/[^\s)]+)\)/
  @cdn_link ~r/https?:\/\/(?:github\.com\/user-attachments\/assets|user-images\.githubusercontent\.com)\/[^\s)\]]+/

  @doc """
  Extracts every image/asset URL embedded in an issue body: markdown
  image links (`![alt](url)`) and GitHub's asset CDN links pasted as
  plain text (`user-attachments/assets/...`,
  `user-images.githubusercontent.com/...`). Pure — no network calls —
  so it's unit-testable without a live issue body.

  Preserves first-occurrence order and dedupes repeats.
  """
  @spec extract_urls(String.t() | nil) :: [String.t()]
  def extract_urls(nil), do: []

  def extract_urls(body) when is_binary(body) do
    markdown_urls = @markdown_image |> Regex.scan(body, capture: :all_but_first) |> List.flatten()
    cdn_urls = @cdn_link |> Regex.scan(body) |> List.flatten()

    Enum.uniq(markdown_urls ++ cdn_urls)
  end

  @doc """
  Downloads every URL `extract_urls/1` finds in `issue_body` and
  stores each as a `TaskAttachment` on `task`, tagged
  `source: :github_issue`. A failure fetching or storing any single
  URL is logged and skipped — never fatal to the sync.
  """
  @spec import_from_issue!(Task.t(), String.t() | nil) :: :ok
  def import_from_issue!(%Task{} = task, issue_body) do
    issue_body
    |> extract_urls()
    |> Enum.each(&import_url(task, &1))

    :ok
  end

  defp import_url(task, url) do
    with {:ok, %Req.Response{status: status, body: body}} when status in 200..299 <-
           Req.get(url: url, retry: false),
         {:ok, tmp_path} <- write_tmp(body) do
      filename = filename_for(url)
      {:ok, storage_key, byte_size} = AttachmentStore.put(task.id, tmp_path, filename)
      File.rm(tmp_path)

      Ash.create!(TaskAttachment, %{
        filename: filename,
        byte_size: byte_size,
        storage_key: storage_key,
        source: :github_issue,
        task_id: task.id
      })
    else
      {:ok, %Req.Response{status: status}} ->
        Logger.warning("IssueAttachments: #{url} returned status #{status}; skipping")

      {:error, reason} ->
        Logger.warning("IssueAttachments: failed to fetch #{url}: #{inspect(reason)}")
    end
  end

  defp write_tmp(body) do
    tmp_path = Path.join(System.tmp_dir!(), "camelot-issue-attachment-#{Ecto.UUID.generate()}")

    case File.write(tmp_path, body) do
      :ok -> {:ok, tmp_path}
      {:error, reason} -> {:error, reason}
    end
  end

  defp filename_for(url) do
    case url |> URI.parse() |> Map.get(:path) |> Path.basename() do
      "" -> "attachment"
      "/" -> "attachment"
      name -> name
    end
  end
end
