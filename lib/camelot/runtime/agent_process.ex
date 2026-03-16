defmodule Camelot.Runtime.AgentProcess do
  @moduledoc """
  GenServer managing a single AI agent's CLI process.
  Opens a Port to the CLI tool (claude/codex), streams
  output via PubSub, and creates Session records on exit.
  """
  use GenServer, restart: :transient

  alias Camelot.Agents.Agent
  alias Camelot.Agents.Session
  alias Camelot.Runtime.AgentRegistry

  require Logger

  defstruct [
    :agent_id,
    :current_task_id,
    :current_session_id,
    :port,
    output_buffer: ""
  ]

  @type t :: %__MODULE__{
          agent_id: String.t(),
          current_task_id: String.t() | nil,
          current_session_id: String.t() | nil,
          port: port() | nil,
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
      case start_cli(state.agent_id, task_id, prompt) do
        {:ok, port, session_id} ->
          new_state = %{
            state
            | port: port,
              current_task_id: task_id,
              current_session_id: session_id,
              output_buffer: ""
          }

          mark_agent_busy(state.agent_id)
          {:reply, :ok, new_state}

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
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

    finish_session(state, exit_code)
    mark_agent_idle(state.agent_id)

    broadcast_agent_update(state.agent_id)

    {:noreply,
     %{
       state
       | port: nil,
         current_task_id: nil,
         current_session_id: nil,
         output_buffer: ""
     }}
  end

  def handle_info({:EXIT, port, _reason}, %{port: port} = state) do
    finish_session(state, 1)
    mark_agent_idle(state.agent_id)
    broadcast_agent_update(state.agent_id)

    {:noreply,
     %{
       state
       | port: nil,
         current_task_id: nil,
         current_session_id: nil,
         output_buffer: ""
     }}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # --- Private ---

  defp start_cli(agent_id, task_id, prompt) do
    agent = Ash.get!(Agent, agent_id)

    cli =
      case agent.type do
        :claude_code -> "claude"
        :codex -> "codex"
      end

    {:ok, session} =
      Ash.create(Session, %{
        agent_id: agent_id,
        task_id: task_id
      })

    port =
      Port.open(
        {:spawn_executable, System.find_executable(cli)},
        [
          :binary,
          :exit_status,
          :use_stdio,
          :stderr_to_stdout,
          args: build_cli_args(agent.type, prompt)
        ]
      )

    {:ok, port, session.id}
  rescue
    e ->
      Logger.error("Failed to start CLI: #{inspect(e)}")
      {:error, :cli_start_failed}
  end

  defp build_cli_args(:claude_code, prompt) do
    ["--print", "--output-format", "text", prompt]
  end

  defp build_cli_args(:codex, prompt) do
    ["--quiet", prompt]
  end

  defp finish_session(state, exit_code) do
    if state.current_session_id do
      session = Ash.get!(Session, state.current_session_id)
      action = if exit_code == 0, do: :complete, else: :fail

      Ash.update(
        session,
        %{
          output_log: state.output_buffer,
          exit_code: exit_code
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
