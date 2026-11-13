defmodule Camelot.Runtime.Runner.SessionEnvTest do
  use ExUnit.Case, async: true

  alias Camelot.Runtime.Runner.SessionEnv
  alias Camelot.Runtime.Runner.Spec

  defp spec(overrides) do
    struct(%Spec{session_id: "sess-1", owner_pid: self(), argv: []}, overrides)
  end

  describe "build/1" do
    test "always carries the session id" do
      assert "CAMELOT_SESSION_ID=sess-1" in SessionEnv.build(spec([]))
    end

    test "passes ATTACHMENTS_JSON when the spec has attachments" do
      json = ~s([{"filename":"a.xlsx","url":"https://x/a"}])
      env = SessionEnv.build(spec(attachments_json: json))

      assert "ATTACHMENTS_JSON=#{json}" in env
    end

    test "omits ATTACHMENTS_JSON when the spec has none" do
      env = SessionEnv.build(spec(attachments_json: nil))

      refute Enum.any?(env, &String.starts_with?(&1, "ATTACHMENTS_JSON="))
    end

    test "passes MCP config and output schema when set" do
      env =
        SessionEnv.build(spec(mcp_config_json: ~s({"m":1}), output_schema_json: ~s({"s":1})))

      assert ~s(PROJECT_MCP_CONFIG_JSON={"m":1}) in env
      assert ~s(CAMELOT_OUTPUT_SCHEMA_JSON={"s":1}) in env
    end

    test "materialises secrets" do
      env =
        SessionEnv.build(spec(secrets: [%{kind: :openai_api_key, name: "k", value: "sk"}]))

      assert "OPENAI_API_KEY=sk" in env
    end
  end
end
