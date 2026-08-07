defmodule Camelot.Runtime.AgentProcessTest do
  use Camelot.DataCase, async: false

  alias Camelot.Accounts.Credential
  alias Camelot.Accounts.User
  alias Camelot.Agents.Agent
  alias Camelot.Board.Task
  alias Camelot.Github.Installation
  alias Camelot.Projects.Membership
  alias Camelot.Projects.Project
  alias Camelot.Runtime.AgentConfig
  alias Camelot.Runtime.AgentProcess
  alias Camelot.Runtime.AgentRegistry
  alias Camelot.Settings.SystemSetting

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

  describe "node_label_for/1" do
    defp agent_with(project_label, owner_label) do
      owner_membership =
        owner_label &&
          %Membership{role: :owner, user: %User{swarm_node_label: owner_label}}

      %Agent{project: %Project{swarm_node_label: project_label, owner_membership: owner_membership}}
    end

    test "a project pin wins over the owner's and the global default" do
      Ash.Seed.seed!(SystemSetting, %{default_swarm_node_label: "global"})

      assert AgentProcess.node_label_for(agent_with("project-pin", "owner-pin")) ==
               "project-pin"
    end

    test "the owner's pin wins when the project has none" do
      Ash.Seed.seed!(SystemSetting, %{default_swarm_node_label: "global"})

      assert AgentProcess.node_label_for(agent_with(nil, "owner-pin")) ==
               "owner-pin"
    end

    test "falls back to the global default when neither is set" do
      Ash.Seed.seed!(SystemSetting, %{default_swarm_node_label: "global"})

      assert AgentProcess.node_label_for(agent_with(nil, nil)) == "global"
    end

    test "returns nil when nothing is pinned anywhere" do
      assert AgentProcess.node_label_for(agent_with(nil, nil)) == nil
    end
  end

  describe "maybe_append_github_app_token/3" do
    setup do
      previous = Application.get_env(:camelot, :github_app)
      on_exit(fn -> Application.put_env(:camelot, :github_app, previous) end)
      :ok
    end

    defp put_app_configured do
      Application.put_env(:camelot, :github_app,
        app_id: "123",
        slug: "camelot-dev",
        client_id: "Iv1.abc",
        client_secret: "secret",
        private_key: Base.encode64("not-a-real-key"),
        webhook_secret: "whsecret"
      )
    end

    defp seed_cached_token(installation_id, token) do
      far_future = DateTime.add(DateTime.utc_now(), 3_600, :second)
      :ets.insert(Camelot.Github.InstallationTokenCache, {installation_id, token, far_future})
    end

    defp task_with_installation(installation_id) do
      installations =
        if installation_id,
          do: [%Installation{installation_id: installation_id, account_login: "acme-org"}],
          else: []

      %Task{creator: %User{github_installations: installations}}
    end

    test "appends a github_app_token secret when the creator has a linked installation and the App is configured" do
      put_app_configured()
      id = System.unique_integer([:positive])
      seed_cached_token(id, "cached-installation-token")

      assert [%{kind: :github_app_token, value: "cached-installation-token"}] =
               AgentProcess.maybe_append_github_app_token([], task_with_installation(id), "task-1")
    end

    test "is a no-op when the creator has no linked installation" do
      put_app_configured()
      assert AgentProcess.maybe_append_github_app_token([], task_with_installation(nil), "task-1") == []
    end

    test "is a no-op when there is no task (bootstrap session)" do
      put_app_configured()
      assert AgentProcess.maybe_append_github_app_token([], nil, "task-1") == []
    end

    test "is a no-op when the App isn't configured" do
      Application.put_env(:camelot, :github_app, [])
      id = System.unique_integer([:positive])
      seed_cached_token(id, "cached-installation-token")

      assert AgentProcess.maybe_append_github_app_token([], task_with_installation(id), "task-1") == []
    end

    test "logs and skips when minting fails (no such installation)" do
      put_app_configured()
      id = System.unique_integer([:positive])

      assert AgentProcess.maybe_append_github_app_token([], task_with_installation(id), "task-1") == []
    end

    test "resolves the installation matching the task's project github_owner when the creator has several" do
      put_app_configured()
      matching_id = System.unique_integer([:positive])
      other_id = System.unique_integer([:positive])
      seed_cached_token(matching_id, "matching-token")
      seed_cached_token(other_id, "other-token")

      task = %Task{
        project: %Project{github_owner: "other-org"},
        creator: %User{
          github_installations: [
            %Installation{installation_id: other_id, account_login: "acme-org"},
            %Installation{installation_id: matching_id, account_login: "other-org"}
          ]
        }
      }

      assert [%{kind: :github_app_token, value: "matching-token"}] =
               AgentProcess.maybe_append_github_app_token([], task, "task-1")
    end

    test "preserves already-built secrets, appending after them" do
      put_app_configured()
      id = System.unique_integer([:positive])
      seed_cached_token(id, "cached-installation-token")

      existing = [%{kind: :ssh_private_key, name: "n", value: "v"}]

      assert [
               %{kind: :ssh_private_key},
               %{kind: :github_app_token, value: "cached-installation-token"}
             ] = AgentProcess.maybe_append_github_app_token(existing, task_with_installation(id), "task-1")
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

  describe "runner_died_message/2" do
    test "prepends the runner log tail so the real cause leads" do
      reason = {:bad_status, 409, %{"message" => "container is not running"}}
      logs = "cloning git@github.com:acme/repo\nERROR: Repository not found."

      msg = AgentProcess.runner_died_message(reason, logs)

      assert String.starts_with?(msg, logs)
      assert msg =~ "runtime detail: runner exited before producing output"
      assert msg =~ "Repository not found"
    end

    test "falls back to the summary when the log tail is nil or blank" do
      reason = %Req.TransportError{reason: :ehostunreach}
      summary = AgentProcess.runner_died_message(reason)

      assert AgentProcess.runner_died_message(reason, nil) == summary
      assert AgentProcess.runner_died_message(reason, "   \n ") == summary
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

  describe "execution_pr_outcome/3" do
    defp exec_state do
      %AgentProcess{
        agent_id: "a",
        config: %AgentConfig{
          parser: :claude_code_json,
          executable: "claude",
          pr_url_pattern: "https://github\\.com/[^\\s]+/pull/(\\d+)"
        }
      }
    end

    test "extracts a PR URL from the final output", ctx do
      text = "All done. Opened https://github.com/T0ha/camelot/pull/42 for review."

      assert {:pr, "https://github.com/T0ha/camelot/pull/42", 42} =
               AgentProcess.execution_pr_outcome(exec_state(), ctx.task, text)
    end

    test "returns :no_pr when no URL and the project has no GitHub repo", ctx do
      # setup project is created without github_owner/repo, so the
      # GitHub fallback short-circuits without a network call.
      assert :no_pr =
               AgentProcess.execution_pr_outcome(
                 exec_state(),
                 ctx.task,
                 "Finished, but I did not open a PR."
               )
    end
  end

  describe "empty_result?/1" do
    defp parsed(overrides) do
      base = %{result_text: "", structured: nil, assistant_texts: [], permission_denials: []}
      {:ok, Map.merge(base, Map.new(overrides))}
    end

    test "true when there is no result, structured, denials, or assistant text" do
      assert AgentProcess.empty_result?(parsed([]))
    end

    test "false when there is result text" do
      refute AgentProcess.empty_result?(parsed(result_text: "done"))
    end

    test "false when there is a structured payload" do
      refute AgentProcess.empty_result?(parsed(structured: %{"decision" => "plan"}))
    end

    test "false when there are permission denials" do
      refute AgentProcess.empty_result?(parsed(permission_denials: [%{"tool_name" => "Bash"}]))
    end

    test "false when an assistant turn has content" do
      refute AgentProcess.empty_result?(parsed(assistant_texts: ["I did the thing"]))
    end

    test "true when assistant turns are all blank" do
      assert AgentProcess.empty_result?(parsed(assistant_texts: ["", "  "]))
    end

    test "false for a runner-death/error parse" do
      refute AgentProcess.empty_result?({:error, "runner died"})
    end
  end

  describe "finish_session/4" do
    test "is a no-op when there is no current session" do
      state = %AgentProcess{agent_id: "a", current_session_id: nil, output_buffer: ""}
      assert :ok = AgentProcess.finish_session(state, 0, nil, [])
    end

    test "does not crash when the session row is missing" do
      state = %AgentProcess{
        agent_id: "a",
        current_session_id: Ecto.UUID.generate(),
        output_buffer: "some output"
      }

      # Ash.get! raises for the missing row; the rescue must swallow it
      # so AgentProcess survives instead of stranding the session.
      assert :ok = AgentProcess.finish_session(state, 1, {:error, "boom"}, [])
    end
  end
end
