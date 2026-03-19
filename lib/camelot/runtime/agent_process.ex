defmodule Camelot.Runtime.AgentProcess do
  @moduledoc """
  GenServer managing a single AI agent's CLI process.
  Opens a Port to the CLI tool (claude/codex), streams
  output via PubSub, and creates Session records on exit.
  Supports automatic retries with exponential backoff.
  """
  use GenServer, restart: :transient

  alias Camelot.Agents.Agent
  alias Camelot.Agents.Session
  alias Camelot.Board.Task
  alias Camelot.Runtime.AgentRegistry
  alias Camelot.Runtime.OutputParser

  require Logger

  @base_retry_delay_ms 5_000

  defstruct [
    :agent_id,
    :agent_type,
    :current_task_id,
    :current_session_id,
    :current_prompt,
    :port,
    max_retries: 0,
    retry_count: 0,
    output_buffer: ""
  ]

  @type t :: %__MODULE__{
          agent_id: String.t(),
          agent_type: :claude_code | :codex | nil,
          current_task_id: String.t() | nil,
          current_session_id: String.t() | nil,
          current_prompt: String.t() | nil,
          port: port() | nil,
          max_retries: non_neg_integer(),
          retry_count: non_neg_integer(),
          output_buffer: String.t()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    agent_id = Keyword.fetch!(opts, :agent_id)

    GenServer.start_link(
      __MODULE__,
      agent_id,
      name: AgentRegistry.via(agent_id)
    )
  end

  @spec dispatch(String.t(), String.t(), String.t()) ::
          :ok | {:error, :busy | :not_found}
  def dispatch(agent_id, task_id, prompt) do
    case AgentRegistry.lookup(agent_id) do
      nil -> {:error, :not_found}
      pid -> GenServer.call(pid, {:dispatch, task_id, prompt})
    end
  end

  @spec retry(String.t()) :: :ok | {:error, :not_found | :no_task}
  def retry(agent_id) do
    case AgentRegistry.lookup(agent_id) do
      nil -> {:error, :not_found}
      pid -> GenServer.call(pid, :retry)
    end
  end

  @spec status(String.t()) ::
          {:ok, :idle | :busy} | {:error, :not_found}
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
  def handle_call({:dispatch, task_id, prompt}, _from, state) do
    if state.port do
      {:reply, {:error, :busy}, state}
    else
      agent = Ash.get!(Agent, state.agent_id)

      case start_cli(state.agent_id, task_id, prompt) do
        {:ok, port, session_id, agent_type} ->
          new_state = %{
            state
            | port: port,
              current_task_id: task_id,
              current_session_id: session_id,
              current_prompt: prompt,
              agent_type: agent_type,
              max_retries: agent.max_retries,
              retry_count: 0,
              output_buffer: ""
          }

          mark_agent_busy(state.agent_id)
          {:reply, :ok, new_state}

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    end
  end

  def handle_call(:retry, _from, state) do
    cond do
      state.port ->
        {:reply, {:error, :busy}, state}

      is_nil(state.current_task_id) || is_nil(state.current_prompt) ->
        {:reply, {:error, :no_task}, state}

      true ->
        do_retry(state, 0)
        {:reply, :ok, state}
    end
  end

  def handle_call(:status, _from, state) do
    status = if state.port, do: :busy, else: :idle
    {:reply, {:ok, status}, state}
  end

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    output = to_string(data)

    Phoenix.PubSub.broadcast(
      Camelot.PubSub,
      "agent:#{state.agent_id}",
      {:agent_output, state.agent_id, output}
    )

    {:noreply, %{state | output_buffer: state.output_buffer <> output}}
  end

  def handle_info({port, {:exit_status, exit_code}}, %{port: port} = state) do
    Logger.info("Agent #{state.agent_id} CLI exited with code #{exit_code}")

    parsed =
      OutputParser.parse(state.agent_type, state.output_buffer)

    finish_session(state, exit_code, parsed)

    failed? = exit_code != 0 or match?({:error, _}, parsed)

    if failed? && state.retry_count < state.max_retries do
      schedule_retry(state)
    else
      submit_task_plan(state, exit_code, parsed)
      mark_agent_idle(state.agent_id)
      broadcast_agent_update(state.agent_id)

      {:noreply, reset_port(state)}
    end
  end

  def handle_info({:EXIT, port, _reason}, %{port: port} = state) do
    parsed =
      OutputParser.parse(
        state.agent_type || :codex,
        state.output_buffer
      )

    finish_session(state, 1, parsed)

    if state.retry_count < state.max_retries do
      schedule_retry(state)
    else
      mark_agent_idle(state.agent_id)
      broadcast_agent_update(state.agent_id)
      {:noreply, reset_port(state)}
    end
  end

  def handle_info(:retry, state) do
    if state.port do
      {:noreply, state}
    else
      do_retry(state, state.retry_count)
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # --- Private ---

  defp schedule_retry(state) do
    delay = retry_delay(state.retry_count)

    Logger.info(
      "Agent #{state.agent_id} scheduling retry " <>
        "#{state.retry_count + 1}/#{state.max_retries} " <>
        "in #{delay}ms"
    )

    Process.send_after(self(), :retry, delay)
    {:noreply, %{state | port: nil, output_buffer: ""}}
  end

  defp do_retry(state, retry_count) do
    next_retry = retry_count + 1

    case start_cli(
           state.agent_id,
           state.current_task_id,
           state.current_prompt,
           next_retry
         ) do
      {:ok, port, session_id, agent_type} ->
        if retry_count == 0, do: mark_agent_busy(state.agent_id)

        new_state = %{
          state
          | port: port,
            current_session_id: session_id,
            agent_type: agent_type,
            retry_count: next_retry,
            output_buffer: ""
        }

        broadcast_agent_update(state.agent_id)
        {:noreply, new_state}

      {:error, reason} ->
        Logger.error(
          "Agent #{state.agent_id} retry failed to start: " <>
            "#{inspect(reason)}"
        )

        mark_agent_idle(state.agent_id)
        broadcast_agent_update(state.agent_id)
        {:noreply, reset_port(state)}
    end
  end

  defp reset_port(state) do
    %{
      state
      | port: nil,
        current_task_id: nil,
        current_session_id: nil,
        current_prompt: nil,
        agent_type: nil,
        retry_count: 0,
        output_buffer: ""
    }
  end

  defp retry_delay(retry_count) do
    @base_retry_delay_ms * Integer.pow(2, retry_count)
  end

  defp start_cli(agent_id, task_id, prompt, retry_number \\ 0) do
    agent = Ash.get!(Agent, agent_id, load: [:project])

    cli =
      case agent.type do
        :claude_code -> System.find_executable("claude")
        :codex -> System.find_executable("codex")
      end

    {:ok, session} =
      Ash.create(Session, %{
        agent_id: agent_id,
        task_id: task_id,
        retry_number: retry_number
      })

    cli_args = build_cli_args(agent.type, prompt)

    case open_port(cli, cli_args, agent.project.path) do
      {:ok, port} ->
        {:ok, port, session.id, agent.type}

      {:error, reason} ->
        fail_session(session, "CLI failed to start: #{inspect(reason)}")
        {:error, :cli_start_failed}
    end
  end

  defp open_port(cli, cli_args, project_path) do
    # Use sh wrapper so stdin is /dev/null — prevents the CLI
    # from blocking on stdin while still capturing stdout/stderr.
    port =
      Port.open(
        {:spawn_executable, System.find_executable("sh")},
        [
          :binary,
          :exit_status,
          :use_stdio,
          :stderr_to_stdout,
          cd: to_charlist(project_path),
          env: [{~c"CLAUDECODE", false}],
          args: [
            "-c",
            ~s(exec "$@" </dev/null),
            "--",
            cli | cli_args
          ]
        ]
      )

    {:ok, port}
  rescue
    e ->
      Logger.error("Failed to open port: #{inspect(e)}")
      {:error, e}
  end

  defp fail_session(session, error_message) do
    Ash.update(
      session,
      %{error_message: error_message},
      action: :fail
    )
  end

  defp build_cli_args(:claude_code, prompt) do
    ["--print", "--output-format", "json", prompt]
  end

  defp build_cli_args(:codex, prompt) do
    ["--quiet", prompt]
  end

  defp submit_task_plan(state, exit_code, parsed) do
    if state.current_task_id && exit_code == 0 &&
         state.output_buffer != "" do
      task = Ash.get!(Task, state.current_task_id)

      plan_text =
        case parsed do
          {:ok, %{result_text: text}} -> text
          {:error, _} -> state.output_buffer
        end

      if task.status == :planning do
        case Ash.update(task, %{plan: plan_text}, action: :submit_plan) do
          {:ok, updated} ->
            broadcast_task_update(updated)

          {:error, error} ->
            Logger.warning(
              "Failed to submit plan for task " <>
                "#{state.current_task_id}: #{inspect(error)}"
            )
        end
      end
    end
  end

  defp broadcast_task_update(task) do
    Phoenix.PubSub.broadcast(
      Camelot.PubSub,
      "task:#{task.id}",
      {:task_updated, task}
    )

    Phoenix.PubSub.broadcast(
      Camelot.PubSub,
      "board",
      {:task_updated, task}
    )
  end

  defp finish_session(state, exit_code, parsed) do
    if state.current_session_id do
      session = Ash.get!(Session, state.current_session_id)
      action = if exit_code == 0, do: :complete, else: :fail

      error_message =
        case parsed do
          {:error, msg} -> msg
          _ -> nil
        end

      Ash.update(
        session,
        %{
          output_log: state.output_buffer,
          exit_code: exit_code,
          error_message: error_message
        },
        action: action
      )
    end
  end

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
end
