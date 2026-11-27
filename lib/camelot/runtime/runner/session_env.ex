defmodule Camelot.Runtime.Runner.SessionEnv do
  @moduledoc """
  Builds the per-session `docker exec` `Env` array from a
  `Camelot.Runtime.Runner.Spec`.

  Shared by the DockerEngine and Swarm `ExecSession`s so the two
  backends can't drift. Each task keeps one long-lived runner
  container that every session `docker exec`s into, and the
  container's create-time env is never updated. So anything that can
  change between sessions travels here instead:

    * secrets (a credential rotated in the UI),
    * the project's MCP config,
    * the stage's structured-output schema,
    * `ATTACHMENTS_JSON`, re-signed every session, so files uploaded
      to the card after the container booted are fetched by
      `/fetch-attachments.sh` before the agent starts.

  `/exec-wrapper.sh` treats `/tmp/camelot.env` (written at boot) as a
  fallback only, so these values win over anything baked in at
  container start.
  """

  alias Camelot.Runtime.Runner.SecretEnv
  alias Camelot.Runtime.Runner.Spec

  @doc """
  Returns the `KEY=value` pairs for one session's exec.
  """
  @spec build(Spec.t()) :: [String.t()]
  def build(%Spec{} = spec) do
    session_id_env(spec) ++
      secret_env(spec) ++
      mcp_env(spec) ++
      output_schema_env(spec) ++
      attachments_env(spec)
  end

  # The exec-wrapper tees output to /tmp/camelot-output-<id>.log so we
  # can fetch it after exit; it needs the session id to name the file.
  defp session_id_env(%Spec{session_id: id}), do: ["CAMELOT_SESSION_ID=#{id}"]

  defp secret_env(%Spec{secrets: secrets}) do
    Enum.flat_map(secrets, &SecretEnv.to_env/1)
  end

  defp mcp_env(%Spec{mcp_config_json: nil}), do: []

  defp mcp_env(%Spec{mcp_config_json: json}) do
    ["PROJECT_MCP_CONFIG_JSON=#{json}"]
  end

  # `exec-wrapper.sh` writes this to `Spec.output_schema_path/1` before
  # running the agent — the path the argv already names.
  defp output_schema_env(%Spec{output_schema_json: nil}), do: []

  defp output_schema_env(%Spec{output_schema_json: json}) do
    ["CAMELOT_OUTPUT_SCHEMA_JSON=#{json}"]
  end

  defp attachments_env(%Spec{attachments_json: nil}), do: []

  defp attachments_env(%Spec{attachments_json: json}) do
    ["ATTACHMENTS_JSON=#{json}"]
  end
end
