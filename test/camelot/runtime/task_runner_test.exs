defmodule Camelot.Runtime.TaskRunnerTest do
  use Camelot.DataCase, async: false

  alias Camelot.Accounts.Credential
  alias Camelot.Accounts.User
  alias Camelot.Agents.Session
  alias Camelot.Board.AttachmentStore
  alias Camelot.Board.Task
  alias Camelot.Board.TaskAttachment
  alias Camelot.Github.Installation
  alias Camelot.Projects.Membership
  alias Camelot.Projects.Project
  alias Camelot.Runtime.AgentConfig
  alias Camelot.Runtime.TaskRegistry
  alias Camelot.Runtime.TaskRunner
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

    {:ok, task} =
      Ash.create(Task, %{
        title: "Process task",
        project_id: project.id,
        creator_id: user.id,
        agent_id: agent!("claude_code").id
      })

    %{task: task, user: user}
  end

  describe "build_secrets/2" do
    test "always mounts the creator's default SSH key, even when " <>
           "the agent CLI does not list :ssh_private_key",
         ctx do
      seed_default_ssh_key!(ctx.task.creator_id, "PRIV-default")

      config = build_config(required_credential_kinds: [])

      assert [
               %{kind: :ssh_private_key, value: "PRIV-default"}
             ] = TaskRunner.build_secrets(ctx.task, config)
    end

    test "appends the default SSH key alongside other agent CLI kinds",
         ctx do
      seed_default_ssh_key!(ctx.task.creator_id, "PRIV-default")

      {:ok, _claude} =
        Ash.create(Credential, %{
          user_id: ctx.task.creator_id,
          kind: :claude_api_key,
          value: "CLAUDE-KEY"
        })

      config = build_config(required_credential_kinds: [:claude_api_key])

      secrets = TaskRunner.build_secrets(ctx.task, config)
      kinds = secrets |> Enum.map(& &1.kind) |> Enum.sort()

      assert kinds == [:claude_api_key, :ssh_private_key]
    end

    test "is a no-op when the creator has no default SSH key " <>
           "and the agent CLI doesn't require one",
         ctx do
      config = build_config(required_credential_kinds: [])
      assert TaskRunner.build_secrets(ctx.task, config) == []
    end

    test "dedupes when the agent CLI also lists :ssh_private_key " <>
           "(agent-fetched credential wins)",
         ctx do
      # Manually-added SSH key (without name="default") — emulates a
      # user who pasted their own pre-feature key.
      {:ok, _manual} =
        Ash.create(Credential, %{
          user_id: ctx.task.creator_id,
          kind: :ssh_private_key,
          name: "my-pasted",
          value: "PRIV-manual"
        })

      seed_default_ssh_key!(ctx.task.creator_id, "PRIV-default")

      config = build_config(required_credential_kinds: [:ssh_private_key])

      secrets = TaskRunner.build_secrets(ctx.task, config)
      assert [%{kind: :ssh_private_key, value: value}] = secrets
      # First-match dedupe preserves the agent-fetched credential.
      assert value in ["PRIV-manual", "PRIV-default"]
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
    defp task_with(project_label, owner_label) do
      owner_membership =
        owner_label &&
          %Membership{role: :owner, user: %User{swarm_node_label: owner_label}}

      %Task{project: %Project{swarm_node_label: project_label, owner_membership: owner_membership}}
    end

    test "a project pin wins over the owner's and the global default" do
      Ash.Seed.seed!(SystemSetting, %{default_swarm_node_label: "global"})

      assert TaskRunner.node_label_for(task_with("project-pin", "owner-pin")) ==
               "project-pin"
    end

    test "the owner's pin wins when the project has none" do
      Ash.Seed.seed!(SystemSetting, %{default_swarm_node_label: "global"})

      assert TaskRunner.node_label_for(task_with(nil, "owner-pin")) ==
               "owner-pin"
    end

    test "falls back to the global default when neither is set" do
      Ash.Seed.seed!(SystemSetting, %{default_swarm_node_label: "global"})

      assert TaskRunner.node_label_for(task_with(nil, nil)) == "global"
    end

    test "returns nil when nothing is pinned anywhere" do
      assert TaskRunner.node_label_for(task_with(nil, nil)) == nil
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

    defp task_with_installation(installation_id) do
      installations =
        if installation_id,
          do: [%Installation{installation_id: installation_id, account_login: "acme-org"}],
          else: []

      %Task{creator: %User{github_installations: installations}}
    end

    # The runner's GitHub token is force-minted fresh per session (never
    # served from the shared cache) so a revoked-but-unexpired cached
    # token can't reach the container. With a fake signing key the mint
    # can't succeed here, so these tests exercise the failure branch: a
    # `:github_token_clear` marker that blanks GH_TOKEN in the runner
    # rather than letting it fall back to a stale token baked into the
    # container. The mint success path is covered by the
    # InstallationTokenCache tests.

    test "clears GH_TOKEN when a fresh token can't be minted for a linked installation" do
      put_app_configured()
      id = System.unique_integer([:positive])

      assert [%{kind: :github_token_clear}] =
               TaskRunner.maybe_append_github_app_token([], task_with_installation(id), "task-1")
    end

    test "appends the clear marker after already-built secrets, preserving them" do
      put_app_configured()
      id = System.unique_integer([:positive])

      existing = [%{kind: :ssh_private_key, name: "n", value: "v"}]

      assert [
               %{kind: :ssh_private_key},
               %{kind: :github_token_clear}
             ] = TaskRunner.maybe_append_github_app_token(existing, task_with_installation(id), "task-1")
    end

    test "flows a multi-installation task through resolution without crashing" do
      # Selection correctness lives in Camelot.Github.ResolverTest; here we
      # only assert the multi-installation path reaches a single decision.
      put_app_configured()
      matching_id = System.unique_integer([:positive])
      other_id = System.unique_integer([:positive])

      task = %Task{
        project: %Project{github_owner: "other-org"},
        creator: %User{
          github_installations: [
            %Installation{installation_id: other_id, account_login: "acme-org"},
            %Installation{installation_id: matching_id, account_login: "other-org"}
          ]
        }
      }

      assert [%{kind: :github_token_clear}] =
               TaskRunner.maybe_append_github_app_token([], task, "task-1")
    end

    test "is a no-op when the creator has no linked installation" do
      put_app_configured()
      assert TaskRunner.maybe_append_github_app_token([], task_with_installation(nil), "task-1") == []
    end

    test "is a no-op when there is no task" do
      put_app_configured()
      assert TaskRunner.maybe_append_github_app_token([], nil, "task-1") == []
    end

    test "leaves GH_TOKEN untouched when the App isn't configured (PAT path)" do
      # No App means we're not on the App-token path at all, so GH_TOKEN
      # must not be cleared — the project may authenticate with a PAT.
      Application.put_env(:camelot, :github_app, [])
      id = System.unique_integer([:positive])

      assert TaskRunner.maybe_append_github_app_token([], task_with_installation(id), "task-1") == []
    end
  end

  describe "start_link/1" do
    test "starts and registers process", ctx do
      {:ok, pid} =
        TaskRunner.start_link(task_id: ctx.task.id)

      assert is_pid(pid)
      assert TaskRegistry.lookup(ctx.task.id) == pid
    end
  end

  describe "dispatch/3" do
    test "returns not_found for an undispatched task" do
      assert {:error, :not_found} =
               TaskRunner.dispatch(
                 "nonexistent",
                 "prompt"
               )
    end
  end

  describe "runner_died_message/1" do
    test "surfaces the transport reason instead of an empty-output guess" do
      reason = %Req.TransportError{reason: :ehostunreach}
      msg = TaskRunner.runner_died_message(reason)

      assert msg =~ "runner exited before producing output"
      assert msg =~ "ehostunreach"
    end
  end

  describe "runner_died_message/2" do
    test "prepends the runner log tail so the real cause leads" do
      reason = {:bad_status, 409, %{"message" => "container is not running"}}
      logs = "cloning git@github.com:acme/repo\nERROR: Repository not found."

      msg = TaskRunner.runner_died_message(reason, logs)

      assert String.starts_with?(msg, logs)
      assert msg =~ "runtime detail: runner exited before producing output"
      assert msg =~ "Repository not found"
    end

    test "falls back to the summary when the log tail is nil or blank" do
      reason = %Req.TransportError{reason: :ehostunreach}
      summary = TaskRunner.runner_died_message(reason)

      assert TaskRunner.runner_died_message(reason, nil) == summary
      assert TaskRunner.runner_died_message(reason, "   \n ") == summary
    end
  end

  describe "planning_action/2" do
    defp planning_state do
      %TaskRunner{
        task_id: "t",
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
               TaskRunner.planning_action(
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
               TaskRunner.planning_action(
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
               TaskRunner.planning_action(planning_state(), res)
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
               TaskRunner.planning_action(planning_state(), res)

      # Uses the FULL transcript, not just the trailing sentence.
      assert text =~ "could you confirm the database name"
    end

    test "without structured output, plain text becomes the plan" do
      res = result(assistant_texts: ["Here is the concrete implementation plan."])

      assert {:submit_plan, "Here is the concrete implementation plan."} =
               TaskRunner.planning_action(planning_state(), res)
    end

    test "empty output yields :empty" do
      assert :empty = TaskRunner.planning_action(planning_state(), result([]))
    end

    test "a non-internal permission denial routes to input" do
      res = result(denials: [%{"tool_name" => "Bash", "tool_input" => %{}}])

      assert {:request_input, _} =
               TaskRunner.planning_action(planning_state(), res)
    end
  end

  describe "plan_file_reference/1" do
    test "extracts an absolute plan file path from prose" do
      plan =
        "See /home/agent/.claude/plans/task-decomission-vectorized.md — " <>
          "full plan written there.\n\nSummary: deep rewrite."

      assert TaskRunner.plan_file_reference(plan) ==
               "/home/agent/.claude/plans/task-decomission-vectorized.md"
    end

    test "extracts a tilde-rooted plan file path" do
      plan = "Full plan: ~/.claude/plans/my-plan.md"

      assert TaskRunner.plan_file_reference(plan) ==
               "~/.claude/plans/my-plan.md"
    end

    test "returns the first reference when several are present" do
      plan =
        "~/.claude/plans/first.md and also " <>
          "/home/agent/.claude/plans/second.md"

      assert TaskRunner.plan_file_reference(plan) ==
               "~/.claude/plans/first.md"
    end

    test "nil when the plan has no plan-file reference" do
      assert TaskRunner.plan_file_reference("Step 1\nStep 2") == nil
    end

    test "nil for paths outside .claude/plans or non-markdown files" do
      assert TaskRunner.plan_file_reference("/home/agent/notes/plan.md") == nil
      assert TaskRunner.plan_file_reference("~/.claude/plans/foo.txt") == nil
      assert TaskRunner.plan_file_reference(nil) == nil
    end
  end

  describe "execution_pr_outcome/3" do
    defp exec_state do
      %TaskRunner{
        task_id: "t",
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
               TaskRunner.execution_pr_outcome(exec_state(), ctx.task, text)
    end

    test "returns :no_pr when no URL and the project has no GitHub repo", ctx do
      # setup project is created without github_owner/repo, so the
      # GitHub fallback short-circuits without a network call.
      assert :no_pr =
               TaskRunner.execution_pr_outcome(
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
      assert TaskRunner.empty_result?(parsed([]))
    end

    test "false when there is result text" do
      refute TaskRunner.empty_result?(parsed(result_text: "done"))
    end

    test "false when there is a structured payload" do
      refute TaskRunner.empty_result?(parsed(structured: %{"decision" => "plan"}))
    end

    test "false when there are permission denials" do
      refute TaskRunner.empty_result?(parsed(permission_denials: [%{"tool_name" => "Bash"}]))
    end

    test "false when an assistant turn has content" do
      refute TaskRunner.empty_result?(parsed(assistant_texts: ["I did the thing"]))
    end

    test "true when assistant turns are all blank" do
      assert TaskRunner.empty_result?(parsed(assistant_texts: ["", "  "]))
    end

    test "false for a runner-death/error parse" do
      refute TaskRunner.empty_result?({:error, "runner died"})
    end
  end

  describe "finish_session/4" do
    test "is a no-op when there is no current session" do
      state = %TaskRunner{task_id: "a", current_session_id: nil, output_buffer: ""}
      assert :ok = TaskRunner.finish_session(state, 0, nil, [])
    end

    test "does not crash when the session row is missing" do
      state = %TaskRunner{
        task_id: "a",
        current_session_id: Ecto.UUID.generate(),
        output_buffer: "some output"
      }

      # Ash.get! raises for the missing row; the rescue must swallow it
      # so TaskRunner survives instead of stranding the session.
      assert :ok = TaskRunner.finish_session(state, 1, {:error, "boom"}, [])
    end

    test "persists cost/duration/usage parsed from a successful result", ctx do
      {:ok, session} =
        Ash.create(Session, %{
          agent_id: ctx.task.agent_id,
          task_id: ctx.task.id
        })

      state = %TaskRunner{
        task_id: ctx.task.id,
        current_session_id: session.id,
        output_buffer: "done"
      }

      parsed =
        {:ok,
         %{
           result_text: "done",
           cost_usd: 0.42,
           duration_ms: 6000,
           duration_api_ms: 5000,
           num_turns: 7,
           usage: %{"input_tokens" => 200, "output_tokens" => 80},
           permission_denials: [],
           structured: nil,
           assistant_texts: ["done"]
         }}

      assert :ok = TaskRunner.finish_session(state, 0, parsed, [])

      reloaded = Ash.get!(Session, session.id)
      assert reloaded.status == :completed
      assert reloaded.cost_usd == 0.42
      assert reloaded.duration_ms == 6000
      assert reloaded.duration_api_ms == 5000
      assert reloaded.num_turns == 7
      assert reloaded.usage == %{"input_tokens" => 200, "output_tokens" => 80}
    end
  end

  describe "handle_info({:task_updated, ...}) with a terminal stage" do
    setup %{task: task} do
      base_dir = Path.join(System.tmp_dir!(), "camelot-attachments-test-#{System.unique_integer([:positive])}")
      previous = Application.get_env(:camelot, :attachments_dir)
      Application.put_env(:camelot, :attachments_dir, base_dir)

      on_exit(fn ->
        File.rm_rf(base_dir)

        if previous do
          Application.put_env(:camelot, :attachments_dir, previous)
        else
          Application.delete_env(:camelot, :attachments_dir)
        end
      end)

      tmp_path = Path.join(base_dir, "src.txt")
      File.mkdir_p!(base_dir)
      File.write!(tmp_path, "bytes")

      {:ok, storage_key, byte_size} = AttachmentStore.put(task.id, tmp_path, "notes.txt")

      {:ok, attachment} =
        Ash.create(TaskAttachment, %{
          filename: "notes.txt",
          byte_size: byte_size,
          storage_key: storage_key,
          task_id: task.id
        })

      %{attachment: attachment}
    end

    test "purges the task's attachments on :done", %{task: task, attachment: attachment} do
      state = %TaskRunner{task_id: task.id}

      assert {:noreply, ^state} =
               TaskRunner.handle_info({:task_updated, %{id: task.id, stage: :done}}, state)

      assert {:error, _} = Ash.get(TaskAttachment, attachment.id)
    end

    test "purges the task's attachments on :cancelled", %{task: task, attachment: attachment} do
      state = %TaskRunner{task_id: task.id}

      assert {:noreply, ^state} =
               TaskRunner.handle_info({:task_updated, %{id: task.id, stage: :cancelled}}, state)

      assert {:error, _} = Ash.get(TaskAttachment, attachment.id)
    end

    test "does nothing for a different task", %{task: task, attachment: attachment} do
      state = %TaskRunner{task_id: "other-task"}

      assert {:noreply, ^state} =
               TaskRunner.handle_info({:task_updated, %{id: task.id, stage: :done}}, state)

      assert {:ok, _} = Ash.get(TaskAttachment, attachment.id)
    end
  end

  describe "handle_info({:runner_interrupted, ...})" do
    test "re-queues the task instead of erroring it", %{task: task, user: user} do
      {:ok, task} = Ash.update(task, %{}, action: :begin_work)
      {:ok, task} = Ash.update(task, %{runner_handle: "svc-1"}, action: :set_runner_handle)

      {:ok, session} =
        Ash.create(Session, %{agent_id: task.agent_id, task_id: task.id, user_id: user.id})

      runner = self()

      state = %TaskRunner{
        task_id: task.id,
        current_session_id: session.id,
        runner: runner,
        # The buffer an adoption reloads is the *previous* run's output.
        # It must not be parsed and re-applied as a result.
        output_buffer: ~s({"type":"result","result":"a plan"})
      }

      assert {:noreply, reset} =
               TaskRunner.handle_info({:runner_interrupted, runner, :container_replaced}, state)

      assert reset.runner == nil
      assert reset.current_session_id == nil

      reloaded = Ash.get!(Task, task.id)
      assert reloaded.state == :queued
      assert reloaded.stage == :planning
      assert reloaded.interrupt_requeues == 1
      # The healthy service is reused rather than rebuilt.
      assert reloaded.runner_handle == "svc-1"

      failed = Ash.get!(Session, session.id)
      assert failed.status == :failed
      assert failed.error_message =~ "interrupted"
    end

    test "ignores a message from a stale runner", %{task: task} do
      state = %TaskRunner{task_id: task.id, runner: self()}
      other = spawn(fn -> :ok end)

      assert {:noreply, ^state} =
               TaskRunner.handle_info({:runner_interrupted, other, :timeout}, state)

      assert Ash.get!(Task, task.id).state == :queued
      assert Ash.get!(Task, task.id).interrupt_requeues == 0
    end
  end
end
