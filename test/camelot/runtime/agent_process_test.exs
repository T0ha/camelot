defmodule Camelot.Runtime.AgentProcessTest do
  use Camelot.DataCase, async: false

  alias Camelot.Accounts.Credential
  alias Camelot.Accounts.User
  alias Camelot.Agents.Agent
  alias Camelot.Board.Task
  alias Camelot.Projects.Project
  alias Camelot.Runtime.AgentConfig
  alias Camelot.Runtime.AgentProcess
  alias Camelot.Runtime.AgentRegistry

  setup do
    {:ok, project} =
      Ash.create(Project, %{
        name: "proc-proj-#{System.unique_integer()}",
        path: "/tmp/proc-proj-#{System.unique_integer()}"
      })

    {:ok, hashed} =
      AshAuthentication.BcryptProvider.hash("Hello world!123")

    user =
      Ash.Seed.seed!(User, %{
        email: "proc-#{System.unique_integer()}@example.com",
        hashed_password: hashed
      })

    {:ok, agent} =
      Ash.create(Agent, %{
        name: "ProcAgent",
        template_id: agent_template!("claude_code").id,
        project_id: project.id,
        user_id: user.id
      })

    {:ok, task} =
      Ash.create(Task, %{
        title: "Process task",
        project_id: project.id,
        creator_id: user.id
      })

    %{agent: agent, task: task}
  end

  describe "build_secrets/2" do
    test "always mounts the user's default SSH key, even when " <>
           "the template does not list :ssh_private_key",
         ctx do
      seed_default_ssh_key!(ctx.agent.user_id, "PRIV-default")

      config = build_config(required_credential_kinds: [])

      assert [
               %{kind: :ssh_private_key, value: "PRIV-default"}
             ] = AgentProcess.build_secrets(ctx.agent, config)
    end

    test "appends the default SSH key alongside other template kinds",
         ctx do
      seed_default_ssh_key!(ctx.agent.user_id, "PRIV-default")

      {:ok, _claude} =
        Ash.create(Credential, %{
          user_id: ctx.agent.user_id,
          kind: :claude_api_key,
          value: "CLAUDE-KEY"
        })

      config = build_config(required_credential_kinds: [:claude_api_key])

      secrets = AgentProcess.build_secrets(ctx.agent, config)
      kinds = secrets |> Enum.map(& &1.kind) |> Enum.sort()

      assert kinds == [:claude_api_key, :ssh_private_key]
    end

    test "is a no-op when the user has no default SSH key " <>
           "and the template doesn't require one",
         ctx do
      config = build_config(required_credential_kinds: [])
      assert AgentProcess.build_secrets(ctx.agent, config) == []
    end

    test "dedupes when the template also lists :ssh_private_key " <>
           "(template-fetched credential wins)",
         ctx do
      # Manually-added SSH key (without name="default") — emulates a
      # user who pasted their own pre-feature key.
      {:ok, _manual} =
        Ash.create(Credential, %{
          user_id: ctx.agent.user_id,
          kind: :ssh_private_key,
          name: "my-pasted",
          value: "PRIV-manual"
        })

      seed_default_ssh_key!(ctx.agent.user_id, "PRIV-default")

      config = build_config(required_credential_kinds: [:ssh_private_key])

      secrets = AgentProcess.build_secrets(ctx.agent, config)
      assert [%{kind: :ssh_private_key, value: value}] = secrets
      # First-match dedupe preserves the template-fetched credential.
      assert value in ["PRIV-manual", "PRIV-default"]
    end

    test "returns [] for an agent with nil user_id (system-owned)", ctx do
      %Agent{} = agent = ctx.agent
      orphan = %{agent | user_id: nil}
      assert AgentProcess.build_secrets(orphan, build_config()) == []
    end

    defp build_config(overrides \\ []) do
      Map.merge(
        struct(AgentConfig, parser: :raw_text, executable: "noop"),
        Map.new(overrides)
      )
    end

    defp seed_default_ssh_key!(user_id, value) do
      {:ok, cred} =
        Ash.create(Credential, %{
          user_id: user_id,
          kind: :ssh_private_key,
          name: "default",
          value: value,
          metadata: %{
            "public_key" => "ssh-ed25519 ZZZ test",
            "fingerprint" => "SHA256:test",
            "algorithm" => "ed25519",
            "source" => "server_generated"
          }
        })

      cred
    end
  end

  describe "start_link/1" do
    test "starts and registers process", ctx do
      {:ok, pid} =
        AgentProcess.start_link(agent_id: ctx.agent.id)

      assert is_pid(pid)
      assert AgentRegistry.lookup(ctx.agent.id) == pid
    end
  end

  describe "status/1" do
    test "returns idle when no task running", ctx do
      {:ok, _pid} =
        AgentProcess.start_link(agent_id: ctx.agent.id)

      assert {:ok, :idle} = AgentProcess.status(ctx.agent.id)
    end

    test "returns not_found for unknown agent" do
      assert {:error, :not_found} =
               AgentProcess.status("nonexistent")
    end
  end

  describe "dispatch/3" do
    test "returns not_found for unregistered agent" do
      assert {:error, :not_found} =
               AgentProcess.dispatch(
                 "nonexistent",
                 "task-id",
                 "prompt"
               )
    end
  end

  describe "runner_died_message/1" do
    test "surfaces the transport reason instead of an empty-output guess" do
      reason = %Req.TransportError{reason: :ehostunreach}
      msg = AgentProcess.runner_died_message(reason)

      assert msg =~ "runner exited before producing output"
      assert msg =~ "ehostunreach"
    end
  end

  describe "planning_action/2" do
    defp planning_state do
      %AgentProcess{
        agent_id: "a",
        config: %AgentConfig{
          parser: :claude_code_json,
          executable: "claude",
          internal_tools: ["ExitPlanMode", "EnterPlanMode"],
          question_phrases: ["waiting for", "could you"]
        }
      }
    end

    defp result(overrides) do
      Map.merge(
        %{text: "", structured: nil, assistant_texts: [], denials: []},
        Map.new(overrides)
      )
    end

    test "structured decision=plan submits the plan text" do
      structured = %{"decision" => "plan", "plan" => "Step 1\nStep 2"}

      assert {:submit_plan, "Step 1\nStep 2"} =
               AgentProcess.planning_action(
                 planning_state(),
                 result(structured: structured)
               )
    end

    test "structured decision=question routes to input with rendered questions" do
      structured = %{
        "decision" => "question",
        "questions" => ["Which DB?", "Which env?"]
      }

      assert {:request_input, text} =
               AgentProcess.planning_action(
                 planning_state(),
                 result(structured: structured)
               )

      assert text == "- Which DB?\n- Which env?"
    end

    test "structured takes precedence over a trailing result sentence" do
      # Reproduces the original bug: the trailing turn is a throwaway
      # sentence, but the structured payload carries the real question.
      structured = %{"decision" => "question", "questions" => ["Which DB?"]}

      res =
        result(
          structured: structured,
          text: "I'll wait for your decision before finalizing.",
          assistant_texts: ["...long question...", "I'll wait for your decision."]
        )

      assert {:request_input, "- Which DB?"} =
               AgentProcess.planning_action(planning_state(), res)
    end

    test "without structured output, a free-text question routes to input" do
      res =
        result(
          text: "Short trailing note.",
          assistant_texts: [
            "I need input: could you confirm the database name?",
            "Short trailing note."
          ]
        )

      assert {:request_input, text} =
               AgentProcess.planning_action(planning_state(), res)

      # Uses the FULL transcript, not just the trailing sentence.
      assert text =~ "could you confirm the database name"
    end

    test "without structured output, plain text becomes the plan" do
      res = result(assistant_texts: ["Here is the concrete implementation plan."])

      assert {:submit_plan, "Here is the concrete implementation plan."} =
               AgentProcess.planning_action(planning_state(), res)
    end

    test "empty output yields :empty" do
      assert :empty = AgentProcess.planning_action(planning_state(), result([]))
    end

    test "a non-internal permission denial routes to input" do
      res = result(denials: [%{"tool_name" => "Bash", "tool_input" => %{}}])

      assert {:request_input, _} =
               AgentProcess.planning_action(planning_state(), res)
    end
  end
end
