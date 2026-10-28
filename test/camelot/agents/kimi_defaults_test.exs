defmodule Camelot.Agents.KimiDefaultsTest do
  use ExUnit.Case, async: true

  alias Camelot.Accounts.Credential
  alias Camelot.Agents.KimiDefaults

  describe "argv shape" do
    test "every run streams JSONL events" do
      assert KimiDefaults.base_args() == ["--output-format", "stream-json"]
      assert KimiDefaults.prompt_flag() == "-p"
      assert KimiDefaults.model_flag() == "-m"
      assert KimiDefaults.executable() == "kimi"
      assert KimiDefaults.parser() == :kimi_jsonl
    end

    # `--plan` cannot be combined with `-p` (the CLI exits 1), so a
    # read-only agent file is the planning posture instead.
    test "planning runs under the read-only agent file" do
      args = KimiDefaults.permission_args_by_stage()

      assert args["planning"] == [
               "--agent-file",
               "/opt/agent-cli/kimi/planning-agent.md"
             ]

      refute "--plan" in args["planning"]
      assert args["executing"] == []
      assert args["pr"] == []
    end

    # Kimi has no schema flag; a non-empty map would make AgentConfig
    # write a schema file nobody reads.
    test "no stage carries an output schema" do
      assert KimiDefaults.output_schema_by_stage() == %{}
    end

    test "every stage gets a kimi system prompt placeholder" do
      assert KimiDefaults.system_prompt_by_stage() == %{
               "planning" => "{{prompt:kimi_planning_system_prompt}}",
               "executing" => "{{prompt:kimi_execution_system_prompt}}",
               "pr" => "{{prompt:kimi_pr_system_prompt}}"
             }
    end

    test "the planning prompt spells out the JSON decision contract" do
      prompt = KimiDefaults.planning_system_prompt()

      assert prompt =~ ~s("decision")
      assert prompt =~ ~s("plan")
      assert prompt =~ ~s("questions")
      assert prompt =~ "no code fences"
    end
  end

  describe "models" do
    # The same alias form `kimi login` writes, so `-m` works on
    # LocalPort and in containers alike.
    test "pinned ids use the kimi-code/ alias form" do
      models = KimiDefaults.available_models()

      assert "kimi-code/k3" in models
      assert Enum.all?(models, &String.starts_with?(&1, "kimi-code/"))
    end

    test "probe tries every endpoint and prefixes the ids" do
      probe = KimiDefaults.models_probe()

      assert probe["candidates"] == [
               "https://api.kimi.ai/coding/v1/models",
               "https://api.moonshot.ai/v1/models",
               "https://api.kimi.com/coding/v1/models",
               "https://api.moonshot.cn/v1/models"
             ]

      assert probe["auth"] == "bearer"
      assert probe["credential_kind"] == "kimi_api_key"
      assert probe["id_prefix"] == "kimi-code/"
      refute Map.has_key?(probe, "url")
    end
  end

  describe "credentials and image" do
    test "requires the one kimi key kind, which the app stores" do
      assert KimiDefaults.required_credential_kinds() == [:kimi_api_key]
      assert :kimi_api_key in Credential.valid_kinds()
    end

    test "runs in the dedicated kimi image" do
      assert KimiDefaults.runner_image() ==
               "ghcr.io/t0ha/camelot-runner-kimi:latest"
    end

    test "env keeps the CLI non-interactive and quiet" do
      assert KimiDefaults.env_vars() == %{
               "KIMI_CODE_TRUST_WORKSPACE" => "1",
               "KIMI_CODE_NO_AUTO_UPDATE" => "1",
               "KIMI_DISABLE_TELEMETRY" => "1"
             }
    end
  end
end
