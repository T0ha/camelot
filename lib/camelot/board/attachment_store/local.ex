defmodule Camelot.Board.AttachmentStore.Local do
  @moduledoc """
  Attachment store backed by a local temporary directory.

  Used by the single-host `DockerEngine`/`LocalPort` runner
  backends — no shared filesystem is needed since agent and
  app run on the same box. Deliberately not a durable/backed-up
  path: attachments are purged when the task's container is
  torn down (see `Camelot.Board.purge_task_attachments!/1`), not
  kept as permanent history.

  The base directory defaults to `System.tmp_dir!()` and is
  overridable via `config :camelot, :attachments_dir` (set from
  `ATTACHMENTS_DIR` in `config/runtime.exs`).
  """

  @behaviour Camelot.Board.AttachmentStore

  @impl true
  @spec put(Ecto.UUID.t(), String.t(), String.t()) ::
          {:ok, String.t(), non_neg_integer()} | {:error, term()}
  def put(task_id, tmp_path, filename) do
    storage_key = Path.join(task_id, unique_filename(filename))
    dest = Path.join(base_dir(), storage_key)

    with :ok <- File.mkdir_p(Path.dirname(dest)),
         :ok <- File.cp(tmp_path, dest),
         {:ok, %File.Stat{size: size}} <- File.stat(dest) do
      {:ok, storage_key, size}
    end
  end

  @impl true
  @spec download_url(String.t()) :: {:local, String.t()}
  def download_url(storage_key) do
    {:local, Path.join(base_dir(), storage_key)}
  end

  @impl true
  @spec delete(String.t()) :: :ok
  def delete(storage_key) do
    File.rm(Path.join(base_dir(), storage_key))
    :ok
  end

  defp base_dir do
    Application.get_env(:camelot, :attachments_dir) ||
      Path.join(System.tmp_dir!(), "camelot-attachments")
  end

  defp unique_filename(filename) do
    "#{Ecto.UUID.generate()}-#{sanitize(filename)}"
  end

  defp sanitize(filename) do
    filename
    |> Path.basename()
    |> String.replace(~r/[^A-Za-z0-9._-]/, "_")
  end
end
