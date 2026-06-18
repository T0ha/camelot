defmodule Camelot.Runtime.AgentProcess do
  @moduledoc """
  GenServer managing a single AI agent's run lifecycle.

  Each session goes through three states inside this
  process:

    1. **queued** — `:dispatch` creates a Session row
       with status `:queued` and asks `RunnerPool` for a
       slot. We return `:ok` to the caller immediately.
    2. **running** — when the pool grants the slot via
       `{:runner_slot, session_id}`, we build a
       `Runner.Spec`, call `Runner.start/1`, and start
       streaming output via PubSub.
    3. **completed/failed** — on `{:runner_exit, _, code}`
       we parse the buffer, finalise the session, release
       the pool slot, and (if the run failed) optionally
       schedule a retry.

  All CLI/parser knobs come from the agent's
  `AgentTemplate` via `AgentConfig`. Backend choice
  (LocalPort / DockerEngine / Swarm) is determined by
  `Camelot.Runtime.Runner`.
  """
  use GenServer, restart: :transient

  alias Camelot.Accounts.Credential
  alias Camelot.Agents.Agent
  alias Camelot.Agents.Session
  alias Camelot.Board.Task
  alias Camelot.Board.TaskMessage
  alias Camelot.Runtime.AgentConfig
  alias Camelot.Runtime.AgentRegistry
  alias Camelot.Runtime.OutputParser
  alias Camelot.Runtime.Runner
  alias Camelot.Runtime.Runner.LocalPort
  alias Camelot.Runtime.Runner.Spec
  alias Camelot.Runtime.RunnerPool
  alias Camelot.Runtime.SecretSync
  alias Camelot.Runtime.SessionRegistry

  require Ash.Query
  require Logger

  defstruct [
    :agent_id,
    :config,
    :current_task_id,
    :current_session_id,
    :current_prompt,
    :runner,
    :user_id,
    max_retries: 0,
    retry_count: 0,
    output_buffer: "",
    allowed_tools: [],
    subscribed_tasks: MapSet.new()
  ]

  @type t :: %__MODULE__{
          agent_id: String.t(),
          config: AgentConfig.t() | nil,
          current_task_id: String.t() | nil,
          current_session_id: String.t() | nil,
          current_prompt: String.t() | nil,
          runner: pid() | nil,
          user_id: String.t() | nil,
          max_retries: non_neg_integer(),
          retry_count: non_neg_integer(),
          output_buffer: String.t(),
          allowed_tools: [String.t()],
          subscribed_tasks: MapSet.t(String.t())
        }

  @unscoped_user "_unscoped"

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    agent_id = Keyword.fetch!(opts, :agent_id)

    GenServer.start_link(
      __MODULE__,
      agent_id,
      name: AgentRegistry.via(agent_id)
    )
  end

  @spec dispatch(String.t(), String.t(), String.t(), [String.t()]) ::
          :ok | {:error, :busy | :not_found}
  def dispatch(agent_id, task_id, prompt, allowed_tools \\ []) do
    case AgentRegistry.lookup(agent_id) do
      nil -> {:error, :not_found}
      pid -> GenServer.call(pid, {:dispatch, task_id, prompt, allowed_tools})
    end
  end

  @spec retry(String.t()) :: :ok | {:error, :not_found | :no_task}
  def retry(agent_id) do
    case AgentRegistry.lookup(agent_id) do
      nil -> {:error, :not_found}
      pid -> GenServer.call(pid, :retry)
    end
  end

  @spec respond_and_retry(String.t(), [String.t()], String.t()) ::
          :ok | {:error, :not_found | :no_task | :busy}
  def respond_and_retry(agent_id, tool_names \\ [], answers_text \\ "") do
    case AgentRegistry.lookup(agent_id) do
      nil -> {:error, :not_found}
      pid -> GenServer.call(pid, {:respond_and_retry, tool_names, answers_text})
    end
  end

  @spec status(String.t()) :: {:ok, :idle | :busy} | {:error, :not_found}
  def status(agent_id) do
    case AgentRegistry.lookup(agent_id) do
      nil -> {:error, :not_found}
      pid -> GenServer.call(pid, :status)
    end
  end

  # --- Server Callbacks ---

  @impl true
  def init(agent_id) do
    Logger.info("AgentProcess started for agent #{agent_id}")
    {:ok, %__MODULE__{agent_id: agent_id}}
  end

  @impl true
  def handle_call({:dispatch, task_id, prompt, allowed_tools}, _from, state) do
    cond do
      state.runner ->
        {:reply, {:error, :busy}, state}

      state.current_session_id ->
        {:reply, {:error, :busy}, state}

      true ->
        case enqueue_session(state, task_id, prompt, allowed_tools, 0) do
          {:ok, new_state} ->
            mark_agent_busy(state.agent_id)
            {:reply, :ok, new_state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
    end
  end

  def handle_call(:retry, _from, state) do
    cond do
      state.runner || state.current_session_id ->
        {:reply, {:error, :busy}, state}

      is_nil(state.current_task_id) || is_nil(state.current_prompt) ->
        {:reply, {:error, :no_task}, state}

      true ->
        case enqueue_session(state, state.current_task_id, state.current_prompt, state.allowed_tools, 0) do
          {:ok, new_state} -> {:reply, :ok, new_state}
          {:error, reason} -> {:reply, {:error, reason}, state}
        end
    end
  end

  def handle_call({:respond_and_retry, tool_names, answers_text}, _from, state) do
    cond do
      state.runner || state.current_session_id ->
        {:reply, {:error, :busy}, state}

      is_nil(state.current_task_id) || is_nil(state.current_prompt) ->
        {:reply, {:error, :no_task}, state}

      true ->
        updated =
          state
          |> apply_tool_approvals(tool_names)
          |> apply_answers(answers_text)

        case enqueue_session(updated, updated.current_task_id, updated.current_prompt, updated.allowed_tools, 0) do
          {:ok, new_state} -> {:reply, :ok, new_state}
          {:error, reason} -> {:reply, {:error, reason}, state}
        end
    end
  end

  def handle_call(:status, _from, state) do
    status = if state.runner || state.current_session_id, do: :busy, else: :idle
    {:reply, {:ok, status}, state}
  end

  @impl true
  def handle_info({:runner_slot, session_id}, state) do
    if state.current_session_id == session_id do
      case start_runner(state) do
        {:ok, runner_pid, config} ->
          mark_session_running(session_id, runner_pid)
          SessionRegistry.register(session_id)
          Process.monitor(runner_pid)
          broadcast_agent_update(state.agent_id)
          state = subscribe_task(state, state.current_task_id)

          {:noreply,
           %{
             state
             | runner: runner_pid,
               config: config,
               output_buffer: ""
           }}

        {:error, reason} ->
          fail_session_for(state, "Runner failed to start: #{inspect(reason)}")
          release_and_idle(state)
          {:noreply, reset_runner(state)}
      end
    else
      Logger.warning(
        "AgentProcess #{state.agent_id} got slot for #{session_id} " <>
          "but current is #{inspect(state.current_session_id)}"
      )

      {:noreply, state}
    end
  end

  def handle_info({:task_updated, %{id: task_id, stage: stage}}, state) when stage in [:done, :cancelled] do
    if MapSet.member?(state.subscribed_tasks, task_id) do
      Logger.info("AgentProcess #{state.agent_id}: task #{task_id} reached #{stage}; tearing down runner")

      Runner.stop_task(task_id)
      Phoenix.PubSub.unsubscribe(Camelot.PubSub, "task:#{task_id}")
      {:noreply, %{state | subscribed_tasks: MapSet.delete(state.subscribed_tasks, task_id)}}
    else
      {:noreply, state}
    end
  end

  def handle_info({:task_updated, _task}, state), do: {:noreply, state}

  def handle_info({:runner_data, handle, data}, %{runner: handle} = state) do
    output = to_string(data)

    Phoenix.PubSub.broadcast(
      Camelot.PubSub,
      "agent:#{state.agent_id}",
      {:agent_output, state.agent_id, output}
    )

    {:noreply, %{state | output_buffer: state.output_buffer <> output}}
  end

  def handle_info({:runner_exit, handle, exit_code}, %{runner: handle} = state) do
    Logger.info("Agent #{state.agent_id} runner exited with code #{exit_code}")

    parsed = OutputParser.parse(parser_for(state), state.output_buffer)
    denials = extract_denials(parsed)
    finish_session(state, exit_code, parsed, denials)
    if state.current_session_id, do: SessionRegistry.unregister(state.current_session_id)

    failed? = exit_code != 0 or match?({:error, _}, parsed)

    if failed? and state.retry_count < state.max_retries do
      release_pool_slot(state)
      schedule_retry(state)
    else
      handle_cli_exit(state, exit_code, parsed)
      if failed?, do: mark_task_error(state.current_task_id)
      release_and_idle(state)

      if denials == [] do
        {:noreply, reset_runner(state)}
      else
        {:noreply, clear_runner(state)}
      end
    end
  end

  # Runner GenServer died without sending us :runner_exit (e.g. a
  # linked Task inside the runner crashed). Treat it as an exit-1
  # so we finalise the session and clean up state — otherwise the
  # AgentProcess sits forever pinned to a dead runner pid.
  def handle_info({:DOWN, _ref, :process, pid, reason}, %{runner: pid} = state) do
    Logger.warning(
      "Agent #{state.agent_id} runner #{inspect(pid)} died without " <>
        "sending exit: #{inspect(reason)}"
    )

    send(self(), {:runner_exit, pid, 1})
    {:noreply, state}
  end

  def handle_info({:DOWN, _, _, _, _}, state), do: {:noreply, state}

  def handle_info(:retry, state) do
    if state.runner || state.current_session_id do
      {:noreply, state}
    else
      case enqueue_session(
             state,
             state.current_task_id,
             state.current_prompt,
             state.allowed_tools,
             state.retry_count + 1
           ) do
        {:ok, new_state} -> {:noreply, new_state}
        {:error, _} -> {:noreply, reset_runner(state)}
      end
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # --- Internals ---

  defp parser_for(%__MODULE__{config: %AgentConfig{parser: p}}), do: p
  defp parser_for(_), do: :raw_text

  defp retry_delay_for(%__MODULE__{config: %AgentConfig{base_retry_delay_ms: ms}}, n) do
    ms * Integer.pow(2, n)
  end

  defp retry_delay_for(_, n), do: 5_000 * Integer.pow(2, n)

  defp schedule_retry(state) do
    delay = retry_delay_for(state, state.retry_count)

    Logger.info(
      "Agent #{state.agent_id} scheduling retry " <>
        "#{state.retry_count + 1}/#{state.max_retries} in #{delay}ms"
    )

    Process.send_after(self(), :retry, delay)
    {:noreply, %{state | runner: nil, output_buffer: "", current_session_id: nil}}
  end

  defp clear_runner(state) do
    %{state | runner: nil, output_buffer: "", retry_count: 0, current_session_id: nil}
  end

  defp reset_runner(state) do
    %{
      state
      | runner: nil,
        current_task_id: nil,
        current_session_id: nil,
        current_prompt: nil,
        config: nil,
        retry_count: 0,
        output_buffer: "",
        allowed_tools: [],
        user_id: nil
    }
  end

  defp apply_tool_approvals(state, []), do: state

  defp apply_tool_approvals(state, tool_names) do
    %{state | allowed_tools: Enum.uniq(state.allowed_tools ++ tool_names)}
  end

  defp apply_answers(state, ""), do: state

  defp apply_answers(state, answers_text) do
    %{
      state
      | current_prompt:
          state.current_prompt <>
            "\n\nUser answers to your questions:\n" <>
            answers_text
    }
  end

  # Creates a queued Session row, enqueues it in the pool,
  # and updates AgentProcess state. The actual runner starts
  # later, when the pool sends {:runner_slot, session_id}.
  defp enqueue_session(state, task_id, prompt, allowed_tools, retry_number) do
    agent = Ash.get!(Agent, state.agent_id, load: [:project, :template, :user])
    config = AgentConfig.resolve(agent)
    user_id = agent_user_id(agent)

    {:ok, session} =
      Ash.create(Session, %{
        agent_id: state.agent_id,
        task_id: task_id,
        user_id: agent.user_id,
        retry_number: retry_number
      })

    {:ok, _} = RunnerPool.enqueue(user_id, session.id, self())

    {:ok,
     %{
       state
       | current_task_id: task_id,
         current_session_id: session.id,
         current_prompt: prompt,
         allowed_tools: allowed_tools,
         config: config,
         user_id: user_id,
         max_retries: agent.max_retries,
         retry_count: retry_number,
         output_buffer: ""
     }}
  rescue
    e ->
      Logger.error("AgentProcess enqueue failed: #{inspect(e)}")
      {:error, e}
  end

  defp agent_user_id(%Agent{user_id: nil}), do: @unscoped_user
  defp agent_user_id(%Agent{user_id: id}), do: id

  defp start_runner(state) do
    agent = Ash.get!(Agent, state.agent_id, load: [:project, :template, :user])
    task = state.current_task_id && Ash.get!(Task, state.current_task_id)
    config = AgentConfig.resolve(agent)

    cli_args =
      AgentConfig.build_cli_args(
        config,
        state.current_prompt,
        state.allowed_tools,
        task && task.stage
      )

    spec = build_spec(state, agent, task, config, cli_args)

    case Runner.start(spec) do
      {:ok, pid} -> {:ok, pid, config}
      {:error, reason} -> {:error, reason}
    end
  end

  defp build_spec(state, agent, task, config, cli_args) do
    prefix_tokens = AgentConfig.prefix_tokens(config, project_path(agent))
    argv = build_argv(prefix_tokens, config.executable, cli_args)
    backend = Runner.backend()

    %Spec{
      session_id: state.current_session_id,
      service_name: Spec.service_name(state.current_session_id),
      owner_pid: self(),
      argv: argv,
      env: config |> AgentConfig.env_for_port() |> normalise_env(),
      image: config.runner_image,
      cwd: cwd_for(backend, agent),
      profile_volume: if(agent.user_id, do: "camelot_user_#{agent.user_id}_profile"),
      resources: config.runner_resources,
      node_label: node_label_for(agent),
      secrets: build_secrets(agent, config),
      repo_url: repo_url_for(backend, agent),
      repo_branch: nil,
      mcp_config_json: build_mcp_config_json(agent),
      bootstrap?: task == nil,
      task_id: task_id_for(backend, task)
    }
  end

  defp task_id_for(LocalPort, _task), do: nil
  defp task_id_for(_backend, %{id: id}) when is_binary(id), do: id
  defp task_id_for(_backend, _task), do: nil

  defp build_argv([], executable, cli_args), do: [executable | cli_args]

  defp build_argv(prefix, executable, cli_args) do
    prefix ++ [executable] ++ cli_args
  end

  defp project_path(%Agent{project: %{path: p}}) when is_binary(p), do: p
  defp project_path(_), do: nil

  defp project_repo_url(%Agent{project: %{github_repo_url: u}}) when is_binary(u), do: u
  defp project_repo_url(_), do: nil

  # LocalPort: BEAM cd's into the host path; the CLI runs there
  # directly. Container backends (DockerEngine, Swarm): /workspace,
  # populated by cloning github_repo_url at session start.
  defp cwd_for(LocalPort, agent), do: project_path(agent)
  defp cwd_for(_backend, _agent), do: "/workspace"

  # DockerEngine and Swarm both clone github_repo_url into the
  # ephemeral /workspace. LocalPort doesn't clone — it runs in-place.
  defp repo_url_for(LocalPort, _agent), do: nil
  defp repo_url_for(_backend, agent), do: project_repo_url(agent)

  defp node_label_for(%Agent{user: %{swarm_node_label: l}}) when is_binary(l), do: l
  defp node_label_for(_), do: nil

  @doc false
  # Builds the secrets list mounted into the runner.
  #
  # Always appends the user's default SSH key (`name: "default"`) when
  # present, regardless of the template's `required_credential_kinds`,
  # so git just works without every template having to declare the
  # requirement. Dedupes by `kind` — the template's explicit entry
  # wins if it's already in the list.
  def build_secrets(%Agent{user_id: nil}, _config), do: []

  def build_secrets(%Agent{user_id: uid}, %AgentConfig{required_credential_kinds: kinds}) do
    template_secrets =
      Enum.flat_map(kinds, fn kind_atom ->
        case fetch_credential(uid, kind_atom) do
          nil ->
            Logger.warning("AgentProcess: missing credential #{kind_atom} for user #{uid}")
            []

          %Credential{value: value} ->
            [
              %{
                kind: kind_atom,
                name: SecretSync.secret_name(uid, kind_atom),
                value: value
              }
            ]
        end
      end)

    template_secrets
    |> append_default_ssh_key(uid)
    |> Enum.uniq_by(& &1.kind)
  end

  defp append_default_ssh_key(secrets, user_id) do
    case fetch_credential(user_id, :ssh_private_key, "default") do
      nil ->
        secrets

      %Credential{value: value} ->
        secrets ++
          [
            %{
              kind: :ssh_private_key,
              name: SecretSync.secret_name(user_id, :ssh_private_key),
              value: value
            }
          ]
    end
  end

  defp fetch_credential(user_id, kind_atom, name \\ nil)

  defp fetch_credential(user_id, kind_atom, nil) do
    Credential
    |> Ash.Query.filter(user_id == ^user_id and kind == ^kind_atom)
    |> Ash.Query.limit(1)
    |> Ash.Query.load(:value)
    |> Ash.read()
    |> case do
      {:ok, [cred | _]} -> cred
      _ -> nil
    end
  end

  defp fetch_credential(user_id, kind_atom, name) do
    Credential
    |> Ash.Query.filter(user_id == ^user_id and kind == ^kind_atom and name == ^name)
    |> Ash.Query.limit(1)
    |> Ash.Query.load(:value)
    |> Ash.read()
    |> case do
      {:ok, [cred | _]} -> cred
      _ -> nil
    end
  end

  defp normalise_env(env) when is_list(env) do
    Map.new(env, fn {k, v} -> {to_string(k), to_string(v)} end)
  end

  defp build_mcp_config_json(%Agent{project: %{mcps: mcps}}) when is_list(mcps) do
    case mcps do
      [] -> nil
      list -> Jason.encode!(Enum.map(list, &mcp_to_map/1))
    end
  end

  defp build_mcp_config_json(_), do: nil

  defp mcp_to_map(mcp) do
    %{name: mcp.name, command: mcp.command, args: mcp.args, env: mcp.env}
  end

  defp release_pool_slot(state) do
    if state.user_id && state.current_session_id do
      RunnerPool.release(state.user_id, state.current_session_id)
    end
  end

  defp release_and_idle(state) do
    release_pool_slot(state)
    mark_agent_idle(state.agent_id)
    broadcast_agent_update(state.agent_id)
  end

  defp fail_session_for(state, message) do
    if state.current_session_id do
      session = Ash.get!(Session, state.current_session_id)
      Ash.update(session, %{error_message: message}, action: :fail)
    end
  end

  defp mark_task_error(nil), do: :ok

  defp mark_task_error(task_id) do
    task = Ash.get!(Task, task_id)
    transition(task, :mark_error)
  end

  # Variant used by paths where the CLI exited cleanly but the
  # post-exit interpretation decided the task is in error (empty
  # plan, no PR URL). `finish_session/4` has already written the
  # session row with status :completed and an empty error_message;
  # annotate it here so the UI can explain *why* the card jumped
  # to :error instead of progressing.
  defp mark_error_with_reason(state, task, reason) do
    annotate_session_error(state.current_session_id, reason)
    transition(task, :mark_error)
  end

  defp annotate_session_error(nil, _reason), do: :ok

  defp annotate_session_error(session_id, reason) do
    case Ash.get(Session, session_id) do
      {:ok, session} ->
        case Ash.update(session, %{error_message: reason}, action: :annotate_error) do
          {:ok, _} ->
            :ok

          {:error, err} ->
            Logger.warning("Failed to annotate session #{session_id} with error reason: #{inspect(err)}")
        end

      {:error, err} ->
        Logger.warning("Failed to load session #{session_id} for error annotation: #{inspect(err)}")
    end
  end

  defp mark_session_running(session_id, runner_pid) do
    session = Ash.get!(Session, session_id)

    Ash.update(
      session,
      %{service_id: inspect(runner_pid)},
      action: :mark_running
    )
  end

  defp handle_cli_exit(state, exit_code, parsed) do
    with task_id when not is_nil(task_id) <- state.current_task_id,
         true <- exit_code == 0 and state.output_buffer != "",
         task = Ash.get!(Task, task_id),
         :in_progress <- task.state do
      denials = extract_denials(parsed)

      result_text =
        case parsed do
          {:ok, %{result_text: text}} -> text
          {:error, _} -> state.output_buffer
        end

      handle_task_result(state, task, result_text, denials, task.id)
    else
      _ -> :ok
    end
  end

  defp handle_task_result(state, %{stage: :planning} = task, text, denials, task_id) do
    plan_from_exit = extract_exit_plan(denials)
    real_denials = reject_internal_denials(state, denials)
    trimmed = String.trim(text || "")

    cond do
      plan_from_exit != nil ->
        submit_plan(task, plan_from_exit, task_id)

      has_questions?(real_denials) or real_denials != [] ->
        input = if trimmed == "", do: "Agent needs tool permissions", else: trimmed
        request_user_input(task, input, task_id)

      question?(state, trimmed) ->
        request_user_input(task, trimmed, task_id)

      trimmed == "" ->
        Logger.warning("Empty plan for task #{task_id}, marking error")

        mark_error_with_reason(
          state,
          task,
          "Agent finished planning without producing a plan."
        )

      true ->
        submit_plan(task, text, task_id)
    end
  end

  defp handle_task_result(state, %{stage: :executing} = task, text, denials, task_id) do
    real_denials = reject_internal_denials(state, denials)

    if has_questions?(real_denials) or real_denials != [] do
      request_user_input(task, text, task_id)
    else
      maybe_create_pr(state, task, text, task_id)
    end
  end

  defp handle_task_result(state, %{stage: :pr} = task, text, denials, task_id) do
    real_denials = reject_internal_denials(state, denials)

    if has_questions?(real_denials) or real_denials != [] do
      request_user_input(task, text, task_id)
    else
      transition(task, :request_input)
    end
  end

  defp handle_task_result(_state, _task, _text, _denials, _task_id), do: :ok

  defp maybe_create_pr(state, task, text, task_id) do
    {pr_url, pr_number} = extract_pr_info(state, text)

    if pr_url do
      case Ash.update(task, %{pr_url: pr_url, pr_number: pr_number}, action: :pr_created) do
        {:ok, updated} ->
          broadcast_task_update(updated)

        {:error, error} ->
          Logger.warning("Failed to mark PR created for task #{task_id}: #{inspect(error)}")
      end
    else
      Logger.warning("Execution completed without PR for task #{task_id}")

      mark_error_with_reason(
        state,
        task,
        "Agent finished executing without opening a PR. " <>
          "No PR URL was found in the agent's final output."
      )
    end
  end

  defp has_questions?(denials) do
    Enum.any?(denials, &(&1["tool_name"] == "AskUserQuestion"))
  end

  defp reject_internal_denials(state, denials) do
    internal = internal_tools(state)
    Enum.reject(denials, &(&1["tool_name"] in internal))
  end

  defp internal_tools(%__MODULE__{config: %AgentConfig{internal_tools: tools}}), do: tools
  defp internal_tools(_), do: []

  defp extract_exit_plan(denials) do
    denials
    |> Enum.find(&(&1["tool_name"] == "ExitPlanMode"))
    |> case do
      %{"tool_input" => %{"plan" => plan}} when is_binary(plan) -> plan
      _ -> nil
    end
  end

  defp extract_pr_info(state, text) when is_binary(text) do
    case AgentConfig.compile_pr_url_pattern(state.config) do
      nil ->
        {nil, nil}

      pattern ->
        case Regex.run(pattern, text) do
          [url, number] -> {url, String.to_integer(number)}
          _ -> {nil, nil}
        end
    end
  end

  defp extract_pr_info(_state, _), do: {nil, nil}

  defp submit_plan(task, plan_text, task_id) do
    case Ash.update(task, %{plan: plan_text}, action: :submit_plan) do
      {:ok, updated} ->
        broadcast_task_update(updated)

      {:error, error} ->
        Logger.warning("Failed to submit plan for task #{task_id}: #{inspect(error)}")
    end
  end

  defp request_user_input(task, text, task_id) do
    Ash.create!(TaskMessage, %{
      role: :assistant,
      content: text,
      task_id: task_id
    })

    transition(task, :request_input)
  end

  defp transition(task, action) do
    case Ash.update(task, %{}, action: action) do
      {:ok, updated} ->
        broadcast_task_update(updated)

      {:error, error} ->
        Logger.warning("Failed #{action} for task #{task.id}: #{inspect(error)}")
    end
  end

  @spec question?(t(), String.t()) :: boolean()
  defp question?(state, text) do
    short? = String.length(text) < 500
    ends_with_question? = String.ends_with?(text, "?")
    lowered = String.downcase(text)
    phrases = question_phrases(state)

    has_question_phrase? = Enum.any?(phrases, &String.contains?(lowered, &1))

    short? and (ends_with_question? or has_question_phrase?)
  end

  defp question_phrases(%__MODULE__{config: %AgentConfig{question_phrases: p}}), do: p
  defp question_phrases(_), do: []

  defp broadcast_task_update(task) do
    Phoenix.PubSub.broadcast(Camelot.PubSub, "task:#{task.id}", {:task_updated, task})
    Phoenix.PubSub.broadcast(Camelot.PubSub, "board", {:task_updated, task})
  end

  defp finish_session(state, exit_code, parsed, denials) do
    if state.current_session_id do
      session = Ash.get!(Session, state.current_session_id)
      action = if exit_code == 0, do: :complete, else: :fail

      error_message =
        case parsed do
          {:error, msg} -> msg
          _ -> nil
        end

      case Ash.update(
             session,
             %{
               output_log: state.output_buffer,
               exit_code: exit_code,
               error_message: error_message,
               permission_denials: denials
             },
             action: action
           ) do
        {:ok, _} ->
          :ok

        {:error, reason} ->
          Logger.error(
            "AgentProcess #{state.agent_id} failed to mark session " <>
              "#{state.current_session_id} as #{action}: #{inspect(reason)}"
          )
      end
    end
  end

  defp extract_denials({:ok, %{permission_denials: d}}), do: d
  defp extract_denials(_), do: []

  defp mark_agent_busy(agent_id) do
    agent = Ash.get!(Agent, agent_id)
    Ash.update!(agent, %{}, action: :mark_busy)
  end

  defp mark_agent_idle(agent_id) do
    agent = Ash.get!(Agent, agent_id)
    Ash.update!(agent, %{}, action: :mark_idle)
  end

  defp broadcast_agent_update(agent_id) do
    agent = Ash.get!(Agent, agent_id, load: [:project])

    Phoenix.PubSub.broadcast(
      Camelot.PubSub,
      "agent:#{agent_id}",
      {:agent_updated, agent}
    )
  end

  # Subscribe once per task so we can react when it hits
  # a terminal stage and tear down the per-task runner.
  defp subscribe_task(state, nil), do: state

  defp subscribe_task(state, task_id) do
    if MapSet.member?(state.subscribed_tasks, task_id) do
      state
    else
      Phoenix.PubSub.subscribe(Camelot.PubSub, "task:#{task_id}")
      %{state | subscribed_tasks: MapSet.put(state.subscribed_tasks, task_id)}
    end
  end
end
