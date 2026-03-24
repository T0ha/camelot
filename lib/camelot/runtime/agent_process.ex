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
  alias Camelot.Board.TaskMessage
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
    output_buffer: "",
    allowed_tools: []
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
          output_buffer: String.t(),
          allowed_tools: [String.t()]
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

  @spec dispatch(String.t(), String.t(), String.t(), [String.t()]) ::
          :ok | {:error, :busy | :not_found}
  def dispatch(agent_id, task_id, prompt, allowed_tools \\ []) do
    case AgentRegistry.lookup(agent_id) do
      nil ->
        {:error, :not_found}

      pid ->
        GenServer.call(
          pid,
          {:dispatch, task_id, prompt, allowed_tools}
        )
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
      nil ->
        {:error, :not_found}

      pid ->
        GenServer.call(
          pid,
          {:respond_and_retry, tool_names, answers_text}
        )
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
  def handle_call({:dispatch, task_id, prompt, allowed_tools}, _from, state) do
    if state.port do
      {:reply, {:error, :busy}, state}
    else
      agent = Ash.get!(Agent, state.agent_id)

      case start_cli(
             state.agent_id,
             task_id,
             prompt,
             0,
             allowed_tools
           ) do
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
              output_buffer: "",
              allowed_tools: allowed_tools
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
        {:noreply, new_state} = do_retry(state, 0)
        {:reply, :ok, new_state}
    end
  end

  def handle_call({:respond_and_retry, tool_names, answers_text}, _from, state) do
    cond do
      state.port ->
        {:reply, {:error, :busy}, state}

      is_nil(state.current_task_id) ||
          is_nil(state.current_prompt) ->
        {:reply, {:error, :no_task}, state}

      true ->
        updated =
          state
          |> apply_tool_approvals(tool_names)
          |> apply_answers(answers_text)

        {:noreply, new_state} = redispatch(updated)
        {:reply, :ok, new_state}
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

    denials = extract_denials(parsed)
    finish_session(state, exit_code, parsed, denials)

    failed? = exit_code != 0 or match?({:error, _}, parsed)

    if failed? && state.retry_count < state.max_retries do
      schedule_retry(state)
    else
      handle_cli_exit(state, exit_code, parsed)
      mark_agent_idle(state.agent_id)
      broadcast_agent_update(state.agent_id)

      if denials == [] do
        {:noreply, reset_port(state)}
      else
        {:noreply, clear_port(state)}
      end
    end
  end

  def handle_info({:EXIT, port, _reason}, %{port: port} = state) do
    parsed =
      OutputParser.parse(
        state.agent_type || :codex,
        state.output_buffer
      )

    finish_session(state, 1, parsed, extract_denials(parsed))

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

  defp redispatch(state) do
    case start_cli(
           state.agent_id,
           state.current_task_id,
           state.current_prompt,
           0,
           state.allowed_tools
         ) do
      {:ok, port, session_id, agent_type} ->
        mark_agent_busy(state.agent_id)
        mark_task_in_progress(state.current_task_id)

        new_state = %{
          state
          | port: port,
            current_session_id: session_id,
            agent_type: agent_type,
            retry_count: 0,
            output_buffer: ""
        }

        broadcast_agent_update(state.agent_id)
        {:noreply, new_state}

      {:error, reason} ->
        Logger.error(
          "Agent #{state.agent_id} redispatch failed: " <>
            "#{inspect(reason)}"
        )

        mark_agent_idle(state.agent_id)
        broadcast_agent_update(state.agent_id)
        {:noreply, reset_port(state)}
    end
  end

  defp do_retry(state, retry_count) do
    next_retry = retry_count + 1

    case start_cli(
           state.agent_id,
           state.current_task_id,
           state.current_prompt,
           next_retry,
           state.allowed_tools
         ) do
      {:ok, port, session_id, agent_type} ->
        if retry_count == 0, do: mark_agent_busy(state.agent_id)
        mark_task_in_progress(state.current_task_id)

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

  defp clear_port(state) do
    %{state | port: nil, output_buffer: "", retry_count: 0}
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
        output_buffer: "",
        allowed_tools: []
    }
  end

  defp apply_tool_approvals(state, []), do: state

  defp apply_tool_approvals(state, tool_names) do
    %{
      state
      | allowed_tools: Enum.uniq(state.allowed_tools ++ tool_names)
    }
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

  defp retry_delay(retry_count) do
    @base_retry_delay_ms * Integer.pow(2, retry_count)
  end

  defp start_cli(agent_id, task_id, prompt, retry_number, allowed_tools) do
    agent = Ash.get!(Agent, agent_id, load: [:project])
    task = Ash.get!(Task, task_id)

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

    permission_stage =
      case task.stage do
        :planning -> :plan
        _ -> :execute
      end

    cli_args =
      build_cli_args(
        agent.type,
        prompt,
        allowed_tools,
        permission_stage
      )

    Logger.info("CLI command: #{cli} #{Enum.join(cli_args, " ")}")

    case open_port(cli, cli_args, agent.project.path) do
      {:ok, port} ->
        {:ok, port, session.id, agent.type}

      {:error, reason} ->
        fail_session(
          session,
          "CLI failed to start: #{inspect(reason)}"
        )

        {:error, :cli_start_failed}
    end
  end

  defp open_port(cli, cli_args, project_path) do
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

  @internal_tools ~w(ExitPlanMode EnterPlanMode)

  defp build_cli_args(:claude_code, prompt, allowed_tools, stage) do
    base = ["--output-format", "json"]

    permission_args =
      case stage do
        :plan -> ["--permission-mode", "plan"]
        :execute -> ["--permission-mode", "acceptEdits"]
      end

    filtered =
      Enum.reject(allowed_tools, fn tool ->
        base_name =
          tool |> String.split("(", parts: 2) |> List.first()

        base_name in @internal_tools
      end)

    tools_args =
      if filtered == [] do
        []
      else
        ["--allowedTools", Enum.join(filtered, ",")]
      end

    base ++ permission_args ++ tools_args ++ ["-p", prompt]
  end

  defp build_cli_args(:codex, prompt, _allowed_tools, _stage) do
    ["--quiet", prompt]
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

      handle_task_result(task, result_text, denials, task.id)
    else
      _ -> :ok
    end
  end

  defp handle_task_result(%{stage: :planning} = task, text, denials, task_id) do
    plan_from_exit = extract_exit_plan(denials)
    real_denials = reject_internal_denials(denials)
    trimmed = String.trim(text || "")

    cond do
      plan_from_exit != nil ->
        submit_plan(task, plan_from_exit, task_id)

      has_questions?(real_denials) or real_denials != [] ->
        input = if trimmed == "", do: "Agent needs tool permissions", else: trimmed
        request_user_input(task, input, task_id)

      question?(trimmed) ->
        request_user_input(task, trimmed, task_id)

      trimmed == "" ->
        Logger.warning("Empty plan for task #{task_id}, marking error")
        transition(task, :mark_error)

      true ->
        submit_plan(task, text, task_id)
    end
  end

  defp handle_task_result(%{stage: :executing} = task, text, denials, task_id) do
    real_denials = reject_internal_denials(denials)

    if has_questions?(real_denials) or real_denials != [] do
      request_user_input(task, text, task_id)
    else
      maybe_create_pr(task, text, task_id)
    end
  end

  defp handle_task_result(%{stage: :pr} = task, text, denials, task_id) do
    real_denials = reject_internal_denials(denials)

    if has_questions?(real_denials) or real_denials != [] do
      request_user_input(task, text, task_id)
    else
      transition(task, :request_input)
    end
  end

  defp handle_task_result(_task, _text, _denials, _task_id), do: :ok

  defp maybe_create_pr(task, text, task_id) do
    {pr_url, pr_number} = extract_pr_info(text)

    if pr_url do
      case Ash.update(
             task,
             %{pr_url: pr_url, pr_number: pr_number},
             action: :pr_created
           ) do
        {:ok, updated} ->
          broadcast_task_update(updated)

        {:error, error} ->
          Logger.warning(
            "Failed to mark PR created for task " <>
              "#{task_id}: #{inspect(error)}"
          )
      end
    else
      Logger.warning("Execution completed without PR for task #{task_id}")

      transition(task, :mark_error)
    end
  end

  defp has_questions?(denials) do
    Enum.any?(denials, &(&1["tool_name"] == "AskUserQuestion"))
  end

  defp reject_internal_denials(denials) do
    Enum.reject(denials, &(&1["tool_name"] in @internal_tools))
  end

  defp extract_exit_plan(denials) do
    denials
    |> Enum.find(&(&1["tool_name"] == "ExitPlanMode"))
    |> case do
      %{"tool_input" => %{"plan" => plan}} when is_binary(plan) -> plan
      _ -> nil
    end
  end

  @pr_url_pattern ~r{https://github\.com/[^\s]+/pull/(\d+)}

  defp extract_pr_info(text) when is_binary(text) do
    case Regex.run(@pr_url_pattern, text) do
      [url, number] -> {url, String.to_integer(number)}
      _ -> {nil, nil}
    end
  end

  defp extract_pr_info(_), do: {nil, nil}

  defp submit_plan(task, plan_text, task_id) do
    case Ash.update(
           task,
           %{plan: plan_text},
           action: :submit_plan
         ) do
      {:ok, updated} ->
        broadcast_task_update(updated)

      {:error, error} ->
        Logger.warning(
          "Failed to submit plan for task " <>
            "#{task_id}: #{inspect(error)}"
        )
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
        Logger.warning(
          "Failed #{action} for task #{task.id}: " <>
            "#{inspect(error)}"
        )
    end
  end

  @question_phrases [
    "could you",
    "can you",
    "please provide",
    "please clarify",
    "please specify",
    "what would",
    "which approach",
    "do you want",
    "would you like",
    "waiting for",
    "need more information",
    "let me know"
  ]

  @spec question?(String.t()) :: boolean()
  defp question?(text) do
    short? = String.length(text) < 500
    ends_with_question? = String.ends_with?(text, "?")
    lowered = String.downcase(text)

    has_question_phrase? =
      Enum.any?(@question_phrases, &String.contains?(lowered, &1))

    short? and (ends_with_question? or has_question_phrase?)
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

  defp finish_session(state, exit_code, parsed, denials) do
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
          error_message: error_message,
          permission_denials: denials
        },
        action: action
      )
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

  defp mark_task_in_progress(task_id) do
    task = Ash.get!(Task, task_id)

    case Ash.update(task, %{}, action: :mark_in_progress) do
      {:ok, updated} -> broadcast_task_update(updated)
      {:error, _} -> :ok
    end
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
