defmodule Camelot.Github.IssueAttachments do
  @moduledoc """
  Imports files embedded in GitHub issue bodies and comments as
  `Camelot.Board.TaskAttachment`s, so the agent finds them under
  `.camelot/attachments/` instead of seeing a link it cannot open.

  Called from three places:

    * `Camelot.Projects.Changes.SyncGithubIssues`: the body of a
      labelled issue, when its task is created (`:github_issue`).
    * `Camelot.Board.Changes.CheckIssuePlan`: trusted plan-review
      comments, before the plan-change transition (`:github_comment`).
    * `Camelot.Board.Changes.CheckPrStatus`: new PR feedback, before
      `:request_pr_changes` (`:github_comment`).

  The callers apply the `Camelot.Github.IssueTrust` and bot-author
  rules, so only comments that also reach the agent as text get their
  files imported.

  Extracted URLs are markdown images (`![alt](url)`) on any host, plus
  GitHub attachment links in any form (`[name](url)` or a bare URL):
  `github.com/user-attachments/assets/...` (images),
  `github.com/user-attachments/files/<id>/<name>` (any other upload:
  xlsx, pdf, zip, csv, ...), `user-images.githubusercontent.com` and
  `private-user-images.githubusercontent.com`. Plain links to other
  hosts are never downloaded.

  Each URL is imported at most once per task (`source_url`). Files are
  capped at 25 MB, the same limit as UI uploads. A file that cannot be
  imported is reported in a `TaskMessage`, so the user and the agent
  both see that it is missing.

  Downloads are unauthenticated. Attachments on public repos work.
  GitHub answers 404 for `user-attachments` links on private repos
  unless the request carries a *user* token. A GitHub App installation
  token is not enough, and Camelot does not store a user token yet.
  Those files fail with a visible `HTTP 404` message.
  """

  alias Camelot.Board.AttachmentStore
  alias Camelot.Board.Task
  alias Camelot.Board.TaskAttachment
  alias Camelot.Board.TaskMessage

  require Ash.Query
  require Logger

  @attachments_dir ".camelot/attachments"
  @max_bytes 25_000_000
  @receive_timeout 30_000

  @attachment_link "https?:\\/\\/(?:github\\.com\\/user-attachments\\/(?:assets|files)|" <>
                     "(?:private-)?user-images\\.githubusercontent\\.com)\\/[^\\s)\\]]+"
  @url_pattern Regex.compile!("!\\[[^\\]]*\\]\\((https?:\\/\\/[^\\s)]+)\\)|(#{@attachment_link})")

  @typedoc "Where an imported attachment came from."
  @type source :: :github_issue | :github_comment

  @typedoc """
  The outcome for one URL:

    * `{:imported, url, attachment}`: downloaded and stored now.
    * `{:existing, url, attachment}`: imported by an earlier poll.
    * `{:failed, url, reason}`: not imported; `reason` is readable.
  """
  @type result ::
          {:imported, String.t(), TaskAttachment.t()}
          | {:existing, String.t(), TaskAttachment.t()}
          | {:failed, String.t(), String.t()}

  @typedoc """
  Options for `import_from_body/3`:

    * `:source`: the `TaskAttachment` source (default `:github_comment`).
    * `:max_bytes`: the size cap (default 25 MB).
  """
  @type option :: {:source, source()} | {:max_bytes, pos_integer()}

  @doc """
  Extracts every attachment URL in `body`: markdown images, and GitHub
  attachment links whether wrapped in `[name](url)` or pasted bare.
  Pure, so it can be tested without a live issue.

  Keeps first-occurrence order and drops repeats.
  """
  @spec extract_urls(String.t() | nil) :: [String.t()]
  def extract_urls(nil), do: []

  def extract_urls(body) do
    @url_pattern
    |> Regex.scan(body, capture: :all_but_first)
    |> Enum.map(&first_capture/1)
    |> Enum.uniq()
  end

  defp first_capture([image_url | _rest]) when image_url != "", do: image_url
  defp first_capture([_image_url, link_url]), do: link_url

  @doc """
  Imports every URL in an issue body as a `:github_issue` attachment.
  Never raises on a failed download: see `import_from_body/3`.
  """
  @spec import_from_issue!(Task.t(), String.t() | nil) :: :ok
  def import_from_issue!(%Task{} = task, issue_body) do
    import_from_body(task, issue_body, source: :github_issue)
    :ok
  end

  @doc """
  Downloads every URL `extract_urls/1` finds in `body` and stores it as
  a `TaskAttachment` on `task`. A URL already imported for the task is
  not downloaded again. Failures are logged, reported in one
  `TaskMessage`, and never raised.
  """
  @spec import_from_body(Task.t(), String.t() | nil, [option()]) :: [result()]
  def import_from_body(%Task{} = task, body, opts \\ []) do
    case extract_urls(body) do
      [] -> []
      urls -> import_urls(task, urls, opts)
    end
  end

  defp import_urls(task, urls, opts) do
    existing = existing_attachments(task)
    by_url = Map.new(existing, &{&1.source_url, &1})
    taken = MapSet.new(existing, & &1.filename)

    {results, _taken} =
      Enum.map_reduce(urls, taken, fn url, taken ->
        by_url
        |> Map.fetch(url)
        |> import_url(task, url, taken, opts)
      end)

    report_failures(task, results)
    results
  end

  defp existing_attachments(task) do
    TaskAttachment
    |> Ash.Query.filter(task_id == ^task.id)
    |> Ash.read!(authorize?: false)
  end

  defp import_url({:ok, attachment}, _task, url, taken, _opts) do
    {{:existing, url, attachment}, taken}
  end

  defp import_url(:error, task, url, taken, opts) do
    case download(url, Keyword.get(opts, :max_bytes, @max_bytes)) do
      {:ok, body, content_type} ->
        filename = url |> filename_for() |> with_extension(content_type) |> unique_filename(taken)
        attrs = %{filename: filename, content_type: content_type, source_url: url}

        task
        |> store(body, attrs, Keyword.get(opts, :source, :github_comment))
        |> stored(url, filename, taken)

      {:error, reason} ->
        {failed(url, reason), taken}
    end
  end

  defp stored({:ok, attachment}, url, filename, taken) do
    {{:imported, url, attachment}, MapSet.put(taken, filename)}
  end

  defp stored({:error, reason}, url, _filename, taken), do: {failed(url, reason), taken}

  defp failed(url, reason) do
    Logger.warning("IssueAttachments: could not import #{url}: #{reason}")
    {:failed, url, reason}
  end

  defp download(url, max_bytes) do
    [url: url, retry: false, decode_body: false, receive_timeout: @receive_timeout]
    |> Req.get(req_options())
    |> downloaded(max_bytes)
  end

  defp downloaded({:ok, %Req.Response{status: status, body: body}}, max_bytes)
       when status in 200..299 and byte_size(body) > max_bytes do
    {:error, "file is larger than #{max_bytes} bytes"}
  end

  defp downloaded({:ok, %Req.Response{status: status} = response}, _max_bytes) when status in 200..299 do
    {:ok, response.body, content_type(response)}
  end

  defp downloaded({:ok, %Req.Response{status: status}}, _max_bytes), do: {:error, "HTTP #{status}"}
  defp downloaded({:error, exception}, _max_bytes), do: {:error, Exception.message(exception)}

  defp content_type(response) do
    case Req.Response.get_header(response, "content-type") do
      [value | _rest] -> value |> String.split(";") |> hd() |> String.trim()
      [] -> nil
    end
  end

  defp req_options do
    :camelot
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:req_options, [])
  end

  defp store(task, body, attrs, source) do
    tmp_path = Path.join(System.tmp_dir!(), "camelot-issue-attachment-#{Ecto.UUID.generate()}")

    with :ok <- File.write(tmp_path, body),
         {:ok, storage_key, byte_size} <- AttachmentStore.put(task.id, tmp_path, attrs.filename) do
      File.rm(tmp_path)

      attrs
      |> Map.merge(%{storage_key: storage_key, byte_size: byte_size, source: source, task_id: task.id})
      |> then(&Ash.create(TaskAttachment, &1, authorize?: false))
      |> created()
    else
      {:error, reason} ->
        File.rm(tmp_path)
        {:error, "could not store the file (#{inspect(reason)})"}
    end
  end

  defp created({:ok, attachment}), do: {:ok, attachment}
  defp created({:error, error}), do: {:error, "could not save the attachment (#{Exception.message(error)})"}

  defp report_failures(task, results) do
    case for {:failed, url, reason} <- results, do: {filename_for(url), reason} do
      [] ->
        :ok

      failures ->
        Ash.create!(TaskMessage, %{role: :user, content: failure_message(failures), task_id: task.id})
        :ok
    end
  end

  defp failure_message(failures) do
    names = Enum.map_join(failures, ", ", &elem(&1, 0))
    lines = Enum.map(failures, fn {name, reason} -> "- #{name}: #{reason}" end)
    header = "Couldn't import attachment #{names} from GitHub, so it is not in #{@attachments_dir}/:"

    Enum.join([header | lines], "\n")
  end

  @doc """
  The filename to store a download from `url` under: the URL-decoded
  last path segment, so `files/<id>/Q3%20report.xlsx` becomes
  `Q3 report.xlsx`. Path separators and control characters are
  replaced with `_`, so the name cannot leave `.camelot/attachments/`.
  An empty, `.` or `..` name becomes `attachment`.
  """
  @spec filename_for(String.t()) :: String.t()
  def filename_for(url) do
    url
    |> URI.parse()
    |> Map.get(:path)
    |> Kernel.||("")
    |> String.split("/")
    |> List.last()
    |> URI.decode()
    |> String.replace(~r/[\/\\\x00-\x1f]/, "_")
    |> safe_filename()
  end

  defp safe_filename(name) when name in ["", ".", ".."], do: "attachment"
  defp safe_filename(name), do: name

  defp with_extension(filename, nil), do: filename

  defp with_extension(filename, content_type) do
    case {Path.extname(filename), MIME.extensions(content_type)} do
      {"", [extension | _rest]} -> "#{filename}.#{extension}"
      _known -> filename
    end
  end

  @doc """
  Returns `filename`, or `name-2.ext`, `name-3.ext`, ... when the name
  is already in `taken`, so two attachments never overwrite each other
  in `.camelot/attachments/`.
  """
  @spec unique_filename(String.t(), MapSet.t(String.t())) :: String.t()
  def unique_filename(filename, taken) do
    extension = Path.extname(filename)
    base = Path.rootname(filename)
    suffixed = 2 |> Stream.iterate(&(&1 + 1)) |> Stream.map(&"#{base}-#{&1}#{extension}")

    [filename]
    |> Stream.concat(suffixed)
    |> Enum.find(&(not MapSet.member?(taken, &1)))
  end

  @doc """
  Rewrites every imported attachment URL in `text` to the local copy
  under `.camelot/attachments/`, so the agent opens the file instead
  of a link it cannot download. `attachments` are `TaskAttachment`s
  (or maps with `:source_url` and `:filename`). Ones without a
  `source_url` are ignored.
  """
  @spec localize_links(String.t() | nil, [%{source_url: String.t() | nil, filename: String.t()}]) ::
          String.t()
  def localize_links(nil, _attachments), do: ""

  def localize_links(text, attachments) do
    attachments
    |> Enum.filter(&is_binary(&1.source_url))
    |> Enum.reduce(text, fn attachment, acc ->
      String.replace(acc, attachment.source_url, "#{@attachments_dir}/#{attachment.filename}")
    end)
  end
end
