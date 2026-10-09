defmodule Camelot.Agents.ModelDiscoveryTest do
  # async: false — the stub is installed in application env, which is
  # deployment-wide, and the `error_ttl` tests override the
  # `:model_discovery` config.
  use Camelot.DataCase, async: false

  alias Camelot.Accounts.Credential
  alias Camelot.Agents.Agent
  alias Camelot.Agents.ClaudeCodeDefaults
  alias Camelot.Agents.ModelDiscovery
  alias Camelot.Board.Task
  alias Camelot.Projects.Project
  alias Camelot.Support.StubModelApi

  @anthropic_url "https://api.anthropic.com/v1/models"
  @openai_url "https://api.openai.com/v1/models"

  setup do
    on_exit(&StubModelApi.uninstall/0)

    :ok
  end

  # One user per test, so the cache key (which carries the user id and
  # a digest of the credential) can never be shared with another.
  defp credentialed_user(kind, value) do
    user = user!()

    Ash.create!(Credential, %{kind: kind, value: value, user_id: user.id})

    user
  end

  defp listing(ids) do
    {:ok, %{"data" => Enum.map(ids, &%{"id" => &1, "object" => "model"})}}
  end

  describe "for_user/2 against Anthropic" do
    test "keeps claude ids only, newest first, on the x-api-key header" do
      user = credentialed_user(:claude_api_key, "sk-ant-api03-live")

      StubModelApi.install(reply: listing(["claude-haiku-4-5", "claude-opus-5-5", "gpt-5.5"]))

      assert {:ok, ["claude-opus-5-5", "claude-haiku-4-5"]} =
               ModelDiscovery.for_user(agent!("claude_code"), user.id)

      assert_received {:list_models, @anthropic_url, headers}
      assert {"x-api-key", "sk-ant-api03-live"} in headers
      assert {"anthropic-version", "2023-06-01"} in headers
    end

    # Anthropic 401s an OAuth access token presented on `x-api-key` —
    # the same split `Runner.SecretEnv.to_env/1` encodes for the runner.
    test "sends an sk-ant-oat token as a Bearer token with the oauth beta" do
      user = credentialed_user(:claude_api_key, "sk-ant-oat01-live")

      StubModelApi.install(reply: listing(["claude-opus-5-5"]))

      assert {:ok, ["claude-opus-5-5"]} =
               ModelDiscovery.for_user(agent!("claude_code"), user.id)

      assert_received {:list_models, @anthropic_url, headers}
      assert {"authorization", "Bearer sk-ant-oat01-live"} in headers
      assert {"anthropic-beta", "oauth-2025-04-20"} in headers
      refute Enum.any?(headers, &match?({"x-api-key", _value}, &1))
    end
  end

  describe "for_user/2 against OpenAI" do
    # The listing is the whole account catalog, so the `include` filter
    # is load-bearing: without it the dropdown would offer whisper-1.
    test "drops everything outside the model families the CLI accepts" do
      user = credentialed_user(:openai_api_key, "sk-proj-live")

      StubModelApi.install(
        reply:
          listing([
            "whisper-1",
            "text-embedding-3-small",
            "dall-e-3",
            "gpt-5.6-terra",
            "codex-mini-latest"
          ])
      )

      assert {:ok, ["gpt-5.6-terra", "codex-mini-latest"]} =
               ModelDiscovery.for_user(agent!("codex"), user.id)

      assert_received {:list_models, @openai_url, headers}
      assert {"authorization", "Bearer sk-proj-live"} in headers
    end
  end

  describe "for_user/2 degraded cases" do
    test "no probe configured" do
      user = credentialed_user(:claude_api_key, "sk-ant-api03-noprobe")

      assert {:error, :no_probe} = ModelDiscovery.for_user(unprobed_agent(), user.id)
    end

    test "a probe naming a credential kind this app doesn't store" do
      user = credentialed_user(:claude_api_key, "sk-ant-api03-badkind")

      agent = probed_agent(%{"credential_kind" => "gemini_api_key"})

      assert {:error, :no_probe} = ModelDiscovery.for_user(agent, user.id)
    end

    test "a probe missing its url" do
      user = credentialed_user(:claude_api_key, "sk-ant-api03-nourl")

      agent = probed_agent(%{}, drop: ["url"])

      assert {:error, :no_probe} = ModelDiscovery.for_user(agent, user.id)
    end

    test "the user holds no credential of the probe's kind" do
      user = user!()

      assert {:error, :no_credential} =
               ModelDiscovery.for_user(agent!("claude_code"), user.id)
    end

    test "a 401 is classified as :forbidden" do
      user = credentialed_user(:claude_api_key, "sk-ant-api03-revoked")

      StubModelApi.install(reply: {:error, {:http_error, 401, %{"error" => "x"}}})

      assert {:error, :forbidden} =
               ModelDiscovery.for_user(agent!("claude_code"), user.id)
    end

    test "a transport failure is classified as :transport_error" do
      user = credentialed_user(:claude_api_key, "sk-ant-api03-offline")

      StubModelApi.install(reply: {:error, %Req.TransportError{reason: :nxdomain}})

      assert {:error, :transport_error} =
               ModelDiscovery.for_user(agent!("claude_code"), user.id)
    end
  end

  describe "models_for/2" do
    test "returns the discovered list when the probe answers" do
      user = credentialed_user(:claude_api_key, "sk-ant-api03-discovered")

      StubModelApi.install(reply: listing(["claude-opus-5-5"]))

      assert ModelDiscovery.models_for(agent!("claude_code"), user.id) ==
               ["claude-opus-5-5"]
    end

    test "falls back to the pinned available_models when the probe fails" do
      user = credentialed_user(:claude_api_key, "sk-ant-api03-failing")
      agent = agent!("claude_code")

      StubModelApi.install(reply: {:error, %Req.TransportError{reason: :timeout}})

      assert ModelDiscovery.models_for(agent, user.id) == agent.available_models
    end

    # An empty answer is a filter that matched nothing, or an account
    # with no entitlements the probe could see. Either way, offering
    # nothing would be worse than offering the admin's pinned list.
    test "falls back when the probe answers with nothing usable" do
      user = credentialed_user(:claude_api_key, "sk-ant-api03-empty")
      agent = agent!("claude_code")

      StubModelApi.install(reply: listing(["gpt-5.5"]))

      assert ModelDiscovery.models_for(agent, user.id) == agent.available_models
    end

    test "falls back when the user holds no credential" do
      agent = agent!("claude_code")

      assert ModelDiscovery.models_for(agent, user!().id) == agent.available_models
    end

    test "a task form with no agent picked yet offers nothing" do
      assert ModelDiscovery.models_for(nil, user!().id) == []
    end
  end

  describe "caching" do
    test "a second call for the same user and credential never reaches the provider" do
      user = credentialed_user(:claude_api_key, "sk-ant-api03-cached")

      StubModelApi.install(reply: listing(["claude-opus-5-5"]))

      assert {:ok, models} = ModelDiscovery.for_user(agent!("claude_code"), user.id)
      assert_received {:list_models, _url, _headers}

      assert {:ok, ^models} = ModelDiscovery.for_user(agent!("claude_code"), user.id)
      refute_received {:list_models, _url, _headers}
    end

    # The key carries a digest of the credential value, so a rotation
    # invalidates the entry with no eviction hook anywhere.
    test "rotating the credential re-probes" do
      user = credentialed_user(:claude_api_key, "sk-ant-api03-before")

      StubModelApi.install(reply: listing(["claude-opus-5-5"]))

      assert {:ok, _models} = ModelDiscovery.for_user(agent!("claude_code"), user.id)
      assert_received {:list_models, _url, _headers}

      user.id
      |> Credential.for_user_and_kind(:claude_api_key)
      |> Ash.update!(%{value: "sk-ant-api03-after"}, action: :rotate)

      assert {:ok, _models} = ModelDiscovery.for_user(agent!("claude_code"), user.id)
      assert_received {:list_models, _url, _headers}
    end

    # A dead provider must not cost a request timeout on every board
    # render, but a user who fixes their key must recover promptly —
    # hence the short negative TTL.
    test "a failure is re-probed once error_ttl has passed" do
      put_discovery_config(ttl: to_timeout(hour: 1), error_ttl: 1)

      user = credentialed_user(:claude_api_key, "sk-ant-api03-retry")

      StubModelApi.install(reply: {:error, %Req.TransportError{reason: :timeout}})

      assert {:error, :transport_error} =
               ModelDiscovery.for_user(agent!("claude_code"), user.id)

      assert_received {:list_models, _url, _headers}

      Process.sleep(20)

      StubModelApi.install(reply: listing(["claude-opus-5-5"]))

      assert {:ok, ["claude-opus-5-5"]} =
               ModelDiscovery.for_user(agent!("claude_code"), user.id)
    end
  end

  # The dropdown and the changeset must agree: a model the form offered
  # because the provider listed it has to be saveable, or the whole
  # feature is cosmetic.
  describe "Task next_model validation" do
    setup do
      user = credentialed_user(:claude_api_key, "sk-ant-api03-task")

      project =
        Ash.create!(Project, %{name: "md-#{System.unique_integer([:positive])}", path: "/tmp/md"})

      StubModelApi.install(reply: listing(["claude-opus-5-5"]))

      %{user: user, project: project}
    end

    test "accepts a discovered model that isn't pinned on create", ctx do
      agent = agent!("claude_code")
      refute "claude-opus-5-5" in agent.available_models

      assert {:ok, task} = create_task(ctx, %{next_model: "claude-opus-5-5"})
      assert task.next_model == "claude-opus-5-5"
    end

    test "accepts a discovered model that isn't pinned via set_next_model", ctx do
      {:ok, task} = create_task(ctx, %{})

      assert {:ok, updated} =
               Ash.update(task, %{next_model: "claude-opus-5-5"}, action: :set_next_model)

      assert updated.next_model == "claude-opus-5-5"
    end

    test "still rejects a model in neither the discovered nor the pinned set", ctx do
      assert {:error, error} = create_task(ctx, %{next_model: "not-a-real-model"})
      assert Enum.any?(error.errors, &(&1.field == :next_model))
    end
  end

  defp create_task(ctx, attrs) do
    defaults = %{
      title: "md-task-#{System.unique_integer([:positive])}",
      project_id: ctx.project.id,
      creator_id: ctx.user.id,
      agent_id: agent!("claude_code").id
    }

    Ash.create(Task, Map.merge(defaults, attrs))
  end

  defp put_discovery_config(config) do
    previous = Application.get_env(:camelot, :model_discovery)
    on_exit(fn -> Application.put_env(:camelot, :model_discovery, previous) end)
    Application.put_env(:camelot, :model_discovery, config)
  end

  defp unprobed_agent do
    Ash.create!(Agent, %{
      slug: "unprobed-#{System.unique_integer([:positive])}",
      name: "Unprobed",
      executable: "unprobed",
      available_models: ["pinned-only"]
    })
  end

  defp probed_agent(overrides, opts \\ []) do
    probe =
      ClaudeCodeDefaults.models_probe()
      |> Map.merge(overrides)
      |> Map.drop(Keyword.get(opts, :drop, []))

    Ash.create!(Agent, %{
      slug: "probed-#{System.unique_integer([:positive])}",
      name: "Probed",
      executable: "probed",
      models_probe: probe
    })
  end
end
