defmodule Camelot.Runtime.Runner.SecretEnv do
  @moduledoc """
  Maps a `Camelot.Runtime.Runner.Spec` secret to the
  `KEY=value` env pairs a runner container/exec needs.
  Shared by the DockerEngine (`TaskContainer`,
  `ExecSession`) and Swarm (`ExecSession`) backends so the
  mapping can't drift between them.
  """

  @type secret :: %{kind: atom(), name: String.t(), value: String.t()}

  @doc """
  Converts one secret into its env pairs.

  `sk-ant-oat*` is an OAuth access token — Anthropic
  401s if it's sent on the `x-api-key` header
  (`ANTHROPIC_API_KEY`), so Claude reads it from
  `CLAUDE_CODE_OAUTH_TOKEN` instead. `ANTHROPIC_API_KEY`
  is explicitly cleared alongside it so a value baked
  into the container at create time (an earlier
  credential, a stale mapping) can't beat the OAuth path
  — `claude` treats an empty value as unset and falls
  back to `CLAUDE_CODE_OAUTH_TOKEN`.
  """
  @spec to_env(secret()) :: [String.t()]
  def to_env(%{kind: :claude_api_key, value: "sk-ant-oat" <> _ = v}) do
    ["CLAUDE_CODE_OAUTH_TOKEN=#{v}", "ANTHROPIC_API_KEY="]
  end

  def to_env(%{kind: :claude_api_key, value: v}) do
    ["ANTHROPIC_API_KEY=#{v}", "CLAUDE_CODE_OAUTH_TOKEN="]
  end

  def to_env(%{kind: :openai_api_key, value: v}), do: ["OPENAI_API_KEY=#{v}"]
  def to_env(%{kind: :codex_api_key, value: v}), do: ["OPENAI_API_KEY=#{v}"]

  def to_env(%{kind: :github_app_token, value: v}) do
    ["GH_TOKEN=#{v}", "GITHUB_TOKEN=#{v}"]
  end

  def to_env(%{kind: kind, value: v}) do
    ["CAMELOT_SECRET_#{String.upcase(Atom.to_string(kind))}=#{v}"]
  end
end
