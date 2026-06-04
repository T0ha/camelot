defmodule Camelot.Runtime.Runner.Spec do
  @moduledoc """
  Everything a runner backend needs to launch one CLI
  invocation: argv, env, mounts, secrets, scheduling
  hints, and the session id it serves.

  Built by `Camelot.Runtime.AgentProcess` from the
  resolved `AgentConfig`, the Agent, its User, and (for
  task sessions) its Project. Backends pattern-match on
  the fields they understand and ignore the rest — the
  spec is intentionally a superset of every backend's
  needs.
  """

  alias Camelot.Runtime.Runner.Spec

  @enforce_keys [:session_id, :owner_pid, :argv]
  defstruct session_id: nil,
            owner_pid: nil,
            argv: [],
            env: %{},
            image: nil,
            cwd: nil,
            profile_volume: nil,
            secrets: [],
            mcp_config_json: nil,
            repo_url: nil,
            repo_branch: nil,
            bootstrap?: false,
            node_label: nil,
            resources: %{},
            service_name: nil

  @type secret :: %{kind: atom(), name: String.t(), value: String.t()}

  @type t :: %Spec{
          session_id: String.t(),
          owner_pid: pid(),
          argv: [String.t()],
          env: %{optional(String.t()) => String.t()},
          image: String.t() | nil,
          cwd: String.t() | nil,
          profile_volume: String.t() | nil,
          secrets: [secret()],
          mcp_config_json: String.t() | nil,
          repo_url: String.t() | nil,
          repo_branch: String.t() | nil,
          bootstrap?: boolean(),
          node_label: String.t() | nil,
          resources: %{optional(String.t()) => String.t()},
          service_name: String.t() | nil
        }

  @doc """
  Stable, deterministic service/container name. The
  Reconciler relies on this naming to adopt containers
  after a Camelot restart without storing the service
  id in the DB.
  """
  @spec service_name(String.t()) :: String.t()
  def service_name(session_id), do: "camelot-runner-#{session_id}"
end
