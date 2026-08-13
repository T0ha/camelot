defmodule Camelot.Board.AttachmentStore.S3 do
  @moduledoc """
  Attachment store backed by an S3-compatible object store (OCI
  Object Storage's S3-compatible API in production).

  Used by the `Swarm` cluster runner backend, where task
  containers can land on any node — a shared filesystem isn't
  available, so blobs live in object storage instead. Built on
  `req_s3` (a `Req` plugin) to stay on `Req` per `tech-stack.md`
  instead of adding `ex_aws`/`hackney`.

  Configured via `config :camelot, :attachment_store_s3` (set from
  `ATTACHMENTS_S3_*` env vars in `config/runtime.exs`).
  """

  @behaviour Camelot.Board.AttachmentStore

  @presign_expires_seconds 900

  @impl true
  @spec put(Ecto.UUID.t(), String.t(), String.t()) ::
          {:ok, String.t(), non_neg_integer()} | {:error, term()}
  def put(task_id, tmp_path, filename) do
    storage_key = Path.join(["tasks", task_id, unique_filename(filename)])

    with {:ok, %File.Stat{size: size}} <- File.stat(tmp_path),
         {:ok, body} <- File.read(tmp_path),
         {:ok, response} <- put_object(storage_key, body),
         :ok <- check_status(response) do
      {:ok, storage_key, size}
    end
  end

  defp check_status(%Req.Response{status: status}) when status in 200..299, do: :ok
  defp check_status(%Req.Response{status: status, body: body}), do: {:error, {:put_failed, status, body}}

  @impl true
  @spec download_url(String.t()) :: {:ok, String.t()}
  def download_url(storage_key) do
    config = config()

    url =
      ReqS3.presign_url(
        bucket: config[:bucket],
        key: storage_key,
        endpoint_url: config[:endpoint],
        access_key_id: config[:access_key_id],
        secret_access_key: config[:secret_access_key],
        region: config[:region],
        expires: @presign_expires_seconds
      )

    {:ok, url}
  end

  @impl true
  @spec delete(String.t()) :: :ok
  def delete(storage_key) do
    Req.delete(request(), url: object_url(storage_key))
    :ok
  end

  defp put_object(storage_key, body) do
    Req.put(request(), url: object_url(storage_key), body: body)
  end

  defp object_url(storage_key), do: "s3://#{config()[:bucket]}/#{storage_key}"

  defp request do
    config = config()

    Req.new()
    |> ReqS3.attach(aws_endpoint_url_s3: config[:endpoint])
    |> Req.merge(
      aws_sigv4: [
        access_key_id: config[:access_key_id],
        secret_access_key: config[:secret_access_key],
        region: config[:region],
        service: :s3
      ]
    )
  end

  defp config, do: Application.get_env(:camelot, :attachment_store_s3, [])

  defp unique_filename(filename) do
    "#{Ecto.UUID.generate()}-#{sanitize(filename)}"
  end

  defp sanitize(filename) do
    filename
    |> Path.basename()
    |> String.replace(~r/[^A-Za-z0-9._-]/, "_")
  end
end
