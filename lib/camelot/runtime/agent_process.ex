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
  alias Camelot.Github.AppConfig
  alias Camelot.Github.Client
  alias Camelot.Github.InstallationTokenCache
  alias Camelot.Github.Resolver
  alias Camelot.Runtime.AgentConfig
  alias Camelot.Runtime.AgentRegistry
  alias Camelot.Runtime.EnvVarResolver
  alias Camelot.Runtime.OutputParser
  alias Camelot.Runtime.Runner
  alias Camelot.Runtime.Runner.DockerApi
  alias Camelot.Runtime.Runner.LocalPort
  alias Camelot.Runtime.Runner.Spec
  alias Camelot.Runtime.Runner.Swarm
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

  @doc """
  Re-attach to a `:running` session whose runner container survived a
  Camelot restart, instead of failing it. Reads the durable tee'd
  output on completion and finalises normally. The caller must have
  ensured the AgentProcess is started (see `Reconciler`).
  """
  @spec adopt(String.t(), String.t()) :: :ok | {:error, :busy | :not_found}
  def adopt(agent_id, session_id) do
    case AgentRegistry.lookup(agent_id) do
      nil -> {:error, :not_found}
      pid -> GenServer.call(pid, {:adopt, session_id})
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

  def handle_call({:adopt, session_id}, _from, state) do
    if state.runner || state.current_session_id do
      {:reply, {:error, :busy}, state}
    else
      case start_adoption(state, session_id) do
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

  # Authoritative output fetched from the runner's tee'd file after
  # the process exited. Replaces (not appends to) the streamed buffer,
  # which may be incomplete if the live exec stream was severed on a
  # long, quiet run. Arrives just before `{:runner_exit, ...}`.
  def handle_info({:runner_output, handle, bytes}, %{runner: handle} = state) do
    {:noreply, %{state | output_buffer: to_string(bytes)}}
  end

  def handle_info({:runner_exit, handle, exit_code}, %{runner: handle} = state) do
    Logger.info("Agent #{state.agent_id} runner exited with code #{exit_code}")
    finalize_runner_exit(state, exit_code, nil)
  end

  # Runner GenServer died without sending us :runner_exit (e.g. a
  # linked Task inside the runner crashed, or the exec never
  # started because the node proxy was unreachable). Finalise as
  # exit-1 so we clean up — otherwise the AgentProcess sits forever
  # pinned to a dead runner pid. The death `reason` is threaded
  # through so the session records it instead of the misleading
  # "empty output" the parser would infer from an empty buffer.
  def handle_info({:DOWN, _ref, :process, pid, reason}, %{runner: pid} = state) do
    Logger.warning(
      "Agent #{state.agent_id} runner #{inspect(pid)} died without " <>
        "sending exit: #{inspect(reason)}"
    )

    finalize_runner_exit(state, 1, reason)
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

  # Shared finalisation for a runner leaving. A clean exit passes
  # `died_reason: nil` and the result is parsed from the captured
  # output buffer; an abnormal death passes the exit `reason`, whose
  # message is recorded directly (the buffer is meaningless there).
  defp finalize_runner_exit(state, exit_code, died_reason) do
    parsed = parsed_for_exit(state, died_reason)
    denials = extract_denials(parsed)
    empty? = exit_code == 0 and empty_result?(parsed)
    finish_session(state, exit_code, parsed, denials, empty?)
    if state.current_session_id, do: SessionRegistry.unregister(state.current_session_id)

    failed? = exit_code != 0 or match?({:error, _}, parsed)

    # A clean-but-empty run (agent produced nothing actionable) is retried
    # on the same footing as a failure — bounded by the agent's
    # `max_retries` — instead of silently parking the task.
    if (failed? or empty?) and state.retry_count < state.max_retries do
      release_pool_slot(state)
      schedule_retry(state)
    else
      finalize_terminal(state, exit_code, parsed, denials, failed?, empty?)
    end
  end

  # Terminal handling once retries are exhausted (or none configured). An
  # empty run bypasses the stage handlers and errors the task with a clear
  # reason, so it never lands in a message-less `waiting_for_input`.
  defp finalize_terminal(state, exit_code, parsed, denials, failed?, empty?) do
    if empty? do
      mark_task_error(state.current_task_id, empty_error_reason(state))
    else
      handle_cli_exit(state, exit_code, parsed)
      if failed?, do: mark_task_error(state.current_task_id, parsed_error(parsed))
    end

    release_and_idle(state)

    if denials == [] do
      {:noreply, reset_runner(state)}
    else
      {:noreply, clear_runner(state)}
    end
  end

  @doc """
  Whether a parsed run produced nothing actionable: no result text, no
  structured payload, no permission denials, and no non-blank assistant
  turns. Such a run is retried (up to the agent's `max_retries`) and its
  session is marked `:empty`, rather than silently parking the task in
  `waiting_for_input`.
  """
  @spec empty_result?(term()) :: boolean()
  def empty_result?({:ok, parsed}) do
    blank?(parsed.result_text) and is_nil(parsed.structured) and
      (parsed.permission_denials || []) == [] and
      Enum.all?(parsed.assistant_texts || [], &blank?/1)
  end

  def empty_result?(_parsed), do: false

  defp blank?(nil), do: true
  defp blank?(text) when is_binary(text), do: String.trim(text) == ""
  defp blank?(_other), do: false

  defp empty_error_reason(%{max_retries: 0}) do
    "Agent finished without producing any output."
  end

  defp empty_error_reason(%{max_retries: retries}) do
    "Agent finished without producing any output after " <>
      "#{retries + 1} attempts."
  end

  defp parsed_for_exit(state, nil) do
    OutputParser.parse(parser_for(state), state.output_buffer)
  end

  defp parsed_for_exit(state, reason) do
    {:error, runner_died_message(reason, runner_log_tail(state))}
  end

  # Best-effort fetch of the dead runner's container log tail. When a
  # runner exits before the exec stream attaches (e.g. the entrypoint's
  # git clone fails), the output buffer is empty and the exit reason is
  # an opaque Docker error — the actual cause lives only in the
  # container logs. Any failure here (service already gone, proxy
  # unreachable) collapses to `nil` so finalisation never crashes.
  @spec runner_log_tail(t()) :: String.t() | nil
  defp runner_log_tail(%__MODULE__{current_task_id: task_id}) when is_binary(task_id) do
    service = Spec.task_runner_name(task_id)

    case DockerApi.service_logs(service, tail: 50) do
      {:ok, logs} -> logs
      {:error, _} -> nil
    end
  rescue
    error ->
      Logger.debug("runner_log_tail failed for task #{task_id}: #{inspect(error)}")
      nil
  end

  defp runner_log_tail(_state), do: nil

  @doc false
  @spec runner_died_message(term()) :: String.t()
  def runner_died_message(reason), do: runner_died_message(reason, nil)

  # Two-arity variant that prepends the runner's log tail (the useful
  # cause) when we managed to fetch it. Logs come first so a truncated
  # card preview shows the real error rather than the opaque Docker
  # exit reason, which is kept as a trailing runtime detail.
  @doc false
  @spec runner_died_message(term(), String.t() | nil) :: String.t()
  def runner_died_message(reason, log_tail) do
    summary = "runner exited before producing output (#{inspect(reason)})"

    case log_tail && String.trim(log_tail) do
      nil -> summary
      "" -> summary
      logs -> "#{logs}\n\nruntime detail: #{summary}"
    end
  end

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
    agent = Ash.get!(Agent, state.agent_id, load: [:template, :user, project: [owner_membership: [:user]]])
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

  # Re-attach to an already-running session after a restart. Rebuilds
  # the minimal state finalisation needs (config, task, output so far)
  # and starts the runner in adopt mode — no pool slot, no new exec.
  defp start_adoption(state, session_id) do
    session = Ash.get!(Session, session_id)
    agent = Ash.get!(Agent, session.agent_id, load: [:template, :user, project: [owner_membership: [:user]]])

    task =
      session.task_id &&
        Ash.get!(Task, session.task_id,
          load: [:project, creator: [:github_installations]],
          authorize?: false
        )

    config = AgentConfig.resolve(agent)

    state = %{
      state
      | current_task_id: session.task_id,
        current_session_id: session.id,
        current_prompt: "",
        allowed_tools: (task && task.allowed_tools) || [],
        config: config,
        user_id: agent_user_id(agent),
        max_retries: agent.max_retries,
        retry_count: session.retry_number,
        output_buffer: session.output_log || ""
    }

    spec = %{
      build_spec(state, agent, task, config, [])
      | adopt?: true,
        adopt_since: session.started_at
    }

    case Runner.start(spec) do
      {:ok, runner_pid} ->
        mark_session_adopted(session_id, runner_pid)
        SessionRegistry.register(session_id)
        Process.monitor(runner_pid)
        broadcast_agent_update(state.agent_id)
        state = subscribe_task(state, session.task_id)
        {:ok, %{state | runner: runner_pid, config: config}}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    e ->
      Logger.error("AgentProcess adopt failed: #{inspect(e)}")
      {:error, e}
  end

  defp mark_session_adopted(session_id, runner_pid) do
    session = Ash.get!(Session, session_id)
    Ash.update(session, %{service_id: inspect(runner_pid)}, action: :mark_adopted)
  end

  defp start_runner(state) do
    agent = Ash.get!(Agent, state.agent_id, load: [:template, :user, project: [owner_membership: [:user]]])

    task =
      state.current_task_id &&
        Ash.get!(Task, state.current_task_id,
          load: [:project, creator: [:github_installations]],
          authorize?: false
        )

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
    task_id = task_id_for(backend, task)

    %Spec{
      session_id: state.current_session_id,
      service_name: Spec.service_name(state.current_session_id),
      owner_pid: self(),
      argv: argv,
      env:
        config
        |> AgentConfig.env_for_port()
        |> normalise_env()
        |> Map.merge(EnvVarResolver.resolve(agent)),
      image: config.runner_image,
      cwd: cwd_for(backend, agent),
      profile_volume: if(agent.user_id, do: "camelot_user_#{agent.user_id}_profile"),
      resources: config.runner_resources,
      node_label: node_label_for(agent),
      secrets: agent |> build_secrets(config) |> maybe_append_github_app_token(task, task_id),
      repo_url: repo_url_for(backend, agent),
      repo_branch: nil,
      mcp_config_json: build_mcp_config_json(agent),
      bootstrap?: task == nil,
      task_id: task_id
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

  @doc false
  # Precedence: a project's own pin wins, then its owner's
  # personal pin, then the instance-wide default. Public (with
  # @doc false) so the precedence table can be unit-tested
  # directly instead of only through build_spec/5.
  @spec node_label_for(Agent.t()) :: String.t() | nil
  def node_label_for(%Agent{project: %{swarm_node_label: p}}) when is_binary(p), do: p

  def node_label_for(%Agent{project: %{owner_membership: %{user: %{swarm_node_label: u}}}}) when is_binary(u), do: u

  def node_label_for(_agent), do: Camelot.Settings.default_swarm_node_label()

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

  @doc false
  # Appends a fresh installation access token when the task's
  # creator has a connected GitHub App installation — independent
  # of `required_credential_kinds`, since there's no per-user
  # Credential kind for this: like SSH, it's automatic once a user
  # has connected GitHub. On the Swarm backend the token is
  # published under a per-task secret name (not shared per-user)
  # so the Reconciler can sweep it independently once the task is
  # done, without racing `SecretSync.reconcile/2`'s
  # delete-then-create dance.
  @spec maybe_append_github_app_token([map()], Task.t() | nil, String.t() | nil) :: [map()]
  def maybe_append_github_app_token(secrets, task, task_id) do
    case installation_id(task) do
      nil -> secrets
      installation_id -> append_github_app_token(secrets, installation_id, task_id)
    end
  end

  defp installation_id(%Task{creator: %{github_installations: installations}} = task) do
    Resolver.installation_id(installations, github_owner(task))
  end

  defp installation_id(_task), do: nil

  defp github_owner(%Task{project: %{github_owner: owner}}), do: owner
  defp github_owner(_task), do: nil

  defp append_github_app_token(secrets, installation_id, task_id) do
    if AppConfig.configured?() do
      mint_github_app_token(secrets, installation_id, task_id)
    else
      secrets
    end
  end

  # Force a fresh mint (never a cached token) so the runner can't inherit
  # a token GitHub revoked early but that is still unexpired in the cache.
  # On failure, append a clear marker rather than nothing: the runner must
  # not silently fall back to the (now-stale) token baked into its
  # container at start time — an expired token 401s every `gh` call and
  # looks like the agent declined to open a PR.
  defp mint_github_app_token(secrets, installation_id, task_id) do
    case InstallationTokenCache.refresh(installation_id) do
      {:ok, token} ->
        name = github_app_token_secret_name(task_id)
        publish_swarm_secret(name, token)
        secrets ++ [%{kind: :github_app_token, name: name, value: token}]

      {:error, reason} ->
        Logger.warning(
          "AgentProcess: could not mint GitHub App token for " <>
            "installation #{installation_id} (#{inspect(reason)}); " <>
            "clearing GH_TOKEN so the runner can't use a stale baked-in token"
        )

        secrets ++ [%{kind: :github_token_clear, name: "", value: ""}]
    end
  end

  defp github_app_token_secret_name(nil), do: "camelot_github_app_token"
  defp github_app_token_secret_name(task_id), do: SecretSync.task_secret_name(task_id, :github_app_token)

  defp publish_swarm_secret(name, value) do
    if Runner.backend() == Swarm, do: SecretSync.put_secret(name, value)
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

  defp mark_task_error(nil, _reason), do: :ok

  defp mark_task_error(task_id, reason) do
    task = Ash.get!(Task, task_id)
    transition(task, :mark_error, %{last_error: reason})
  end

  # Variant used by paths where the CLI exited cleanly but the
  # post-exit interpretation decided the task is in error (empty
  # plan, no PR URL). `finish_session/4` has already written the
  # session row with status :completed and an empty error_message;
  # annotate it here so the UI can explain *why* the card jumped
  # to :error instead of progressing.
  defp mark_error_with_reason(state, task, reason) do
    annotate_session_error(state.current_session_id, reason)
    transition(task, :mark_error, %{last_error: reason})
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
      handle_task_result(state, task, build_result(state, parsed), task.id)
    else
      _ -> :ok
    end
  end

  # Normalises the parser output into the shape the stage handlers
  # consume. `text` is the final result field (used for PR-URL scraping);
  # `assistant_texts` is every top-level assistant turn (used when the
  # plan/question lives in an earlier turn); `structured` is the
  # `--json-schema` payload; `denials` the permission denials.
  defp build_result(_state, {:ok, parsed}) do
    %{
      text: parsed.result_text,
      structured: parsed.structured,
      assistant_texts: parsed.assistant_texts,
      denials: parsed.permission_denials
    }
  end

  defp build_result(state, {:error, _}) do
    %{text: state.output_buffer, structured: nil, assistant_texts: [], denials: []}
  end

  # Planning routes on the `--json-schema` decision first (the reliable
  # path: the agent emits `StructuredOutput` with {decision, plan,
  # questions}). Everything below is a fallback for runs without a
  # structured payload — legacy ExitPlanMode, tool-permission denials, or
  # free text — and reads the FULL assistant transcript so a plan or
  # question raised in an earlier turn is never lost to the trailing
  # result sentence.
  defp handle_task_result(state, %{stage: :planning} = task, result, task_id) do
    case planning_action(state, result) do
      {:submit_plan, plan} ->
        submit_plan(task, plan, task_id)

      {:request_input, text} ->
        request_user_input(task, text, task_id)

      :empty ->
        Logger.warning("Empty plan for task #{task_id}, marking error")

        mark_error_with_reason(
          state,
          task,
          "Agent finished planning without producing a plan."
        )
    end
  end

  defp handle_task_result(state, %{stage: :executing} = task, result, task_id) do
    real_denials = reject_internal_denials(state, result.denials)

    cond do
      questions = structured_questions(result.structured) ->
        request_user_input(task, questions, task_id)

      has_questions?(real_denials) or real_denials != [] ->
        request_user_input(task, result.text, task_id)

      true ->
        maybe_create_pr(state, task, result.text, task_id)
    end
  end

  defp handle_task_result(state, %{stage: :pr} = task, result, task_id) do
    real_denials = reject_internal_denials(state, result.denials)

    cond do
      questions = structured_questions(result.structured) ->
        request_user_input(task, questions, task_id)

      has_questions?(real_denials) or real_denials != [] ->
        request_user_input(task, result.text, task_id)

      true ->
        request_user_input(task, pr_review_message(result), task_id)
    end
  end

  defp handle_task_result(_state, _task, _result, _task_id), do: :ok

  # A clean PR-stage run with no question and no denials: surface the
  # agent's summary so the waiting-for-input email always corresponds to a
  # visible message. A genuinely empty run never reaches here — it is
  # retried and marked `:empty` in `finalize_runner_exit`.
  defp pr_review_message(result) do
    case String.trim(result.text) do
      "" ->
        "I finished reviewing the PR. Please review the changes, or " <>
          "reply with further guidance."

      text ->
        text
    end
  end

  @doc """
  Decides the planning-stage outcome from a parsed runner result.

  Pure (no DB writes) so the routing can be unit-tested. Precedence:
  the `--json-schema` structured decision, then legacy ExitPlanMode,
  then tool-permission denials, then a free-text question, then a
  plain plan; an empty result yields `:empty`.
  """
  @spec planning_action(t(), map()) ::
          {:submit_plan, String.t()}
          | {:request_input, String.t()}
          | :empty
  def planning_action(state, result) do
    structured_action(result.structured) ||
      fallback_action(state, result)
  end

  # The reliable path: a `--json-schema` decision.
  defp structured_action(structured) do
    cond do
      plan = structured_plan(structured) -> {:submit_plan, plan}
      questions = structured_questions(structured) -> {:request_input, questions}
      true -> nil
    end
  end

  # No structured payload: recover from a legacy ExitPlanMode denial,
  # tool-permission denials, or the free-text transcript.
  defp fallback_action(state, result) do
    real_denials = reject_internal_denials(state, result.denials)
    full_text = planning_text(result)
    plan_from_exit = extract_exit_plan(result.denials)

    cond do
      plan_from_exit != nil ->
        {:submit_plan, plan_from_exit}

      has_questions?(real_denials) or real_denials != [] ->
        {:request_input, if(full_text == "", do: "Agent needs tool permissions", else: full_text)}

      question?(state, full_text) ->
        {:request_input, full_text}

      full_text == "" ->
        :empty

      true ->
        {:submit_plan, full_text}
    end
  end

  # Prefer the full assistant transcript (all top-level turns) over the
  # trailing result field, which is only the last turn.
  defp planning_text(%{assistant_texts: [_ | _] = texts}) do
    texts |> Enum.join("\n\n") |> String.trim()
  end

  defp planning_text(%{text: text}), do: String.trim(text || "")

  # A structured "plan" decision carries the full plan text; return it
  # only when non-empty so the caller can fall through otherwise.
  defp structured_plan(%{"decision" => "plan", "plan" => plan}) when is_binary(plan) do
    case String.trim(plan) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp structured_plan(_), do: nil

  # A structured "question" decision carries a list of questions; render
  # them as a single message for the TaskMessage / UI.
  defp structured_questions(%{"decision" => "question", "questions" => qs}) when is_list(qs) and qs != [] do
    qs
    |> Enum.map(&to_string/1)
    |> Enum.map_join("\n", &("- " <> &1))
  end

  defp structured_questions(_), do: nil

  defp maybe_create_pr(state, task, text, task_id) do
    case execution_pr_outcome(state, task, text) do
      {:pr, pr_url, pr_number} ->
        record_pr(task, pr_url, pr_number, task_id)

      :no_pr ->
        Logger.warning("Execution completed without PR for task #{task_id}")
        request_no_pr_input(state, task, task_id)
    end
  end

  @doc """
  Decides whether an execution run produced a PR.

  Prefers a URL scraped from the agent's final output; failing that,
  falls back to querying GitHub for an open PR on the task's dedicated
  `camelot/task-<id>` branch (guards a real PR whose URL never reached
  stdout). Returns `:no_pr` when neither yields one.
  """
  @spec execution_pr_outcome(t(), Task.t(), String.t()) ::
          {:pr, String.t(), pos_integer()} | :no_pr
  def execution_pr_outcome(state, task, text) do
    case extract_pr_info(state, text) do
      {nil, _} -> github_pr_fallback(task)
      {url, number} -> {:pr, url, number}
    end
  end

  defp github_pr_fallback(task) do
    task = Ash.load!(task, [:project, creator: [:github_installations]], authorize?: false)
    find_pr_on_github(task)
  end

  defp find_pr_on_github(%{project: %{github_owner: nil}}), do: :no_pr
  defp find_pr_on_github(%{project: %{github_repo: nil}}), do: :no_pr

  defp find_pr_on_github(%{project: %{github_owner: owner, github_repo: repo}, id: task_id} = task) do
    opts = [installation_id: installation_id(task)]

    case Client.find_open_pr_by_head(owner, repo, "camelot/task-#{task_id}", opts) do
      {:ok, %{"html_url" => url, "number" => number}} ->
        {:pr, url, number}

      _ ->
        :no_pr
    end
  end

  defp record_pr(task, pr_url, pr_number, task_id) do
    case Ash.update(task, %{pr_url: pr_url, pr_number: pr_number}, action: :pr_created) do
      {:ok, updated} ->
        broadcast_task_update(updated)

      {:error, error} ->
        Logger.warning("Failed to mark PR created for task #{task_id}: #{inspect(error)}")
    end
  end

  # Clean exit but no PR: keep the task recoverable instead of dead
  # (:error). Route it to waiting_for_input with an explanation; a reply
  # re-queues the executing stage with the conversation appended.
  defp request_no_pr_input(state, task, task_id) do
    reason =
      "Finished executing but no pull request was opened. Reply to have " <>
        "me open the PR, or give further guidance."

    annotate_session_error(state.current_session_id, reason)
    request_user_input(task, reason, task_id)
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

  defp transition(task, action, params \\ %{}) do
    case Ash.update(task, params, action: action) do
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

  @doc false
  # Finalise the current session row. Wrapped in a rescue so a transient
  # DB error (or a session deleted out from under us) logs and returns
  # instead of crashing AgentProcess mid-finalisation — which would
  # strand the session as :running until the Reconciler swept it.
  @spec finish_session(t(), integer(), term(), [map()], boolean()) :: :ok
  def finish_session(state, exit_code, parsed, denials, empty? \\ false)

  def finish_session(%__MODULE__{current_session_id: nil}, _exit_code, _parsed, _denials, _empty?) do
    :ok
  end

  def finish_session(state, exit_code, parsed, denials, empty?) do
    session = Ash.get!(Session, state.current_session_id)
    action = session_action(exit_code, empty?)

    case Ash.update(
           session,
           %{
             output_log: state.output_buffer,
             exit_code: exit_code,
             error_message: parsed_error(parsed),
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
  rescue
    error ->
      Logger.error(
        "AgentProcess #{state.agent_id} crashed finalising session " <>
          "#{state.current_session_id}: #{Exception.message(error)}"
      )

      :ok
  end

  defp session_action(_exit_code, true), do: :mark_empty
  defp session_action(0, false), do: :complete
  defp session_action(_exit_code, false), do: :fail

  defp parsed_error({:error, msg}), do: msg
  defp parsed_error(_parsed), do: nil

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
