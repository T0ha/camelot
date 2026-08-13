defmodule Camelot.Runtime.Runner.SecretEnvTest do
  use ExUnit.Case, async: true

  alias Camelot.Runtime.Runner.SecretEnv

  describe "to_env/1" do
    test "claude oauth token sets CLAUDE_CODE_OAUTH_TOKEN and clears ANTHROPIC_API_KEY" do
      assert SecretEnv.to_env(%{kind: :claude_api_key, value: "sk-ant-oat01-abc"}) == [
               "CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-abc",
               "ANTHROPIC_API_KEY="
             ]
    end

    test "claude plain api key sets ANTHROPIC_API_KEY and clears the oauth var" do
      assert SecretEnv.to_env(%{kind: :claude_api_key, value: "sk-ant-api-abc"}) == [
               "ANTHROPIC_API_KEY=sk-ant-api-abc",
               "CLAUDE_CODE_OAUTH_TOKEN="
             ]
    end

    test "openai_api_key and codex_api_key both map to OPENAI_API_KEY" do
      assert SecretEnv.to_env(%{kind: :openai_api_key, value: "sk-oai"}) == ["OPENAI_API_KEY=sk-oai"]
      assert SecretEnv.to_env(%{kind: :codex_api_key, value: "sk-oai"}) == ["OPENAI_API_KEY=sk-oai"]
    end

    test "github_app_token sets both GH_TOKEN and GITHUB_TOKEN" do
      assert SecretEnv.to_env(%{kind: :github_app_token, value: "ghs_abc"}) == [
               "GH_TOKEN=ghs_abc",
               "GITHUB_TOKEN=ghs_abc"
             ]
    end

    test "github_token_clear blanks GH_TOKEN and GITHUB_TOKEN so a stale baked-in token is never used" do
      assert SecretEnv.to_env(%{kind: :github_token_clear, name: "", value: ""}) == [
               "GH_TOKEN=",
               "GITHUB_TOKEN="
             ]
    end

    test "unknown kinds fall back to a generic CAMELOT_SECRET_<KIND> var" do
      assert SecretEnv.to_env(%{kind: :ssh_private_key, value: "pk"}) == ["CAMELOT_SECRET_SSH_PRIVATE_KEY=pk"]
      assert SecretEnv.to_env(%{kind: :generic, value: "v"}) == ["CAMELOT_SECRET_GENERIC=v"]
    end
  end
end
