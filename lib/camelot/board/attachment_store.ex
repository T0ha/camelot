defmodule Camelot.Board.AttachmentStore do
  @moduledoc """
  Behaviour every attachment storage backend implements.

  Backend choice is config-selected per deployment, mirroring
  `Camelot.Runtime.Runner`: `Local` (a `System.tmp_dir!()`-based
  temp directory) for the `DockerEngine`/`LocalPort` single-host
  backends, `S3` (OCI Object Storage's S3-compatible API) for the
  `Swarm` cluster backend. Selected in `config/runtime.exs` from the
  same `RUNNER_BACKEND` switch that picks the runner.
  """

  @type storage_key :: String.t()

  @callback put(task_id :: Ecto.UUID.t(), tmp_path :: String.t(), filename :: String.t()) ::
              {:ok, storage_key(), byte_size :: non_neg_integer()} | {:error, term()}

  @callback download_url(storage_key()) ::
              {:ok, String.t()} | {:local, path :: String.t()}

  @callback delete(storage_key()) :: :ok

  @doc """
  Returns the configured attachment store backend module.
  """
  @spec backend() :: module()
  def backend do
    Application.get_env(:camelot, :attachment_store, Camelot.Board.AttachmentStore.Local)
  end

  @doc "Store `tmp_path` for `task_id` using the configured backend."
  @spec put(Ecto.UUID.t(), String.t(), String.t()) ::
          {:ok, storage_key(), non_neg_integer()} | {:error, term()}
  def put(task_id, tmp_path, filename), do: backend().put(task_id, tmp_path, filename)

  @doc "Resolve a download location for `storage_key` using the configured backend."
  @spec download_url(storage_key()) :: {:ok, String.t()} | {:local, String.t()}
  def download_url(storage_key), do: backend().download_url(storage_key)

  @doc "Delete the blob at `storage_key` using the configured backend."
  @spec delete(storage_key()) :: :ok
  def delete(storage_key), do: backend().delete(storage_key)
end
