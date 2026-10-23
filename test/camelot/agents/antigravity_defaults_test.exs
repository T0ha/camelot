defmodule Camelot.Agents.AntigravityDefaultsTest do
  use ExUnit.Case, async: true

  alias Camelot.Agents.AntigravityDefaults

  describe "CLI shape" do
    test "streams line-delimited JSON events" do
      assert AntigravityDefaults.base_args() == ["--output-format", "stream-json"]
    end

    test "passes the prompt and the model as flag values" do
      assert AntigravityDefaults.prompt_flag() == "-p"
      assert AntigravityDefaults.model_flag() == "--model"
    end

    test "reads its output with the :antigravity_json parser" do
      assert AntigravityDefaults.parser() == :antigravity_json
    end

    test "runs in an image that carries the agy binary" do
      assert AntigravityDefaults.runner_image() ==
               "ghcr.io/t0ha/camelot-runner-agy:latest"
    end

    test "requires the Gemini API key" do
      assert AntigravityDefaults.required_credential_kinds() == [:gemini_api_key]
    end
  end

  describe "models" do
    test "the pinned fallback carries the default model" do
      models = AntigravityDefaults.available_models()

      assert AntigravityDefaults.default_model() == "gemini-3.8-flash-high"
      assert AntigravityDefaults.default_model() in models
      assert "claude-sonnet-4-6" in models
    end

    test "the probe asks Google with the Gemini key" do
      probe = AntigravityDefaults.models_probe()

      assert probe["url"] ==
               "https://generativelanguage.googleapis.com/v1beta/models"

      assert probe["auth"] == "google"
      assert probe["credential_kind"] == "gemini_api_key"
      assert probe["list_key"] == "models"
      assert probe["id_key"] == "name"
      assert probe["strip_prefix"] == "models/"
    end
  end

  describe "permission_args_by_stage/0" do
    test "planning runs in plan mode with the inline JSON Schema" do
      planning = AntigravityDefaults.permission_args_by_stage()["planning"]

      assert planning == [
               "--mode",
               "plan",
               "--dangerously-skip-permissions",
               "--json-schema",
               AntigravityDefaults.planning_json_schema()
             ]
    end

    test "executing and pr accept edits with no TTY to approve at" do
      args = AntigravityDefaults.permission_args_by_stage()
      expected = ["--mode", "accept-edits", "--dangerously-skip-permissions"]

      assert args["executing"] == expected
      assert args["pr"] == expected
    end
  end

  describe "planning_json_schema/0" do
    test "encodes the plan-or-question decision" do
      schema = Jason.decode!(AntigravityDefaults.planning_json_schema())

      assert schema["type"] == "object"
      assert schema["required"] == ["decision"]

      assert schema["properties"]["decision"]["enum"] == [
               "plan",
               "question"
             ]

      assert schema["properties"]["plan"]["type"] == "string"
      assert schema["properties"]["questions"]["type"] == "array"
    end
  end

  describe "system prompts" do
    test "every stage is a placeholder for its PromptTemplate slug" do
      assert AntigravityDefaults.system_prompt_by_stage() == %{
               "planning" => "{{prompt:agy_planning_system_prompt}}",
               "executing" => "{{prompt:agy_execution_system_prompt}}",
               "pr" => "{{prompt:agy_pr_system_prompt}}"
             }
    end

    test "slugs name the agy stages" do
      assert AntigravityDefaults.planning_system_prompt_slug() ==
               "agy_planning_system_prompt"

      assert AntigravityDefaults.execution_system_prompt_slug() ==
               "agy_execution_system_prompt"

      assert AntigravityDefaults.pr_system_prompt_slug() ==
               "agy_pr_system_prompt"
    end

    test "the fallback bodies are non-empty" do
      assert AntigravityDefaults.planning_system_prompt() =~ "planning mode"
      assert AntigravityDefaults.execution_system_prompt() =~ "gh pr create"
      assert AntigravityDefaults.pr_system_prompt() =~ "pull request"
    end
  end

  test "question_phrases/0 recognises a clarifying question" do
    assert "could you" in AntigravityDefaults.question_phrases()
  end
end
