defmodule Camelot.Runtime.RunnerPool do
  @moduledoc """
  Queue-based, DB-backed pool of runner slots.

  Sessions enqueue immediately and wait their turn —
  the pool never refuses a dispatch. Per-user and
  global caps control concurrency, not admission.
  Wait time is a UX signal (and a future monetisation
  lever via `per_user_max_overrides`).

  The authoritative queue is the set of
  `Camelot.Agents.Session{status: :queued}` rows in
  the DB. The GenServer state is just a fast index
  over those rows, rebuilt on boot by
  `Camelot.Runtime.Reconciler` calling `tick/0`.

  Each waiter registers a `from_pid` to receive the
  slot grant message `{:runner_slot, session_id}` and
  is monitored so the slot frees if the waiter dies.
  """
  use GenServer

  alias Camelot.Runtime.RunnerPool.State

  require Logger

  @name __MODULE__

  defmodule State do
    @moduledoc false

    defstruct active: %{},
              queue: %{},
              waiters: %{},
              monitors: %{},
              global_max: 20,
              per_user_max: 2,
              per_user_max_overrides: %{}

    @type session_id :: String.t()
    @type user_id :: String.t()

    @type t :: %__MODULE__{
            active: %{user_id() => MapSet.t(session_id())},
            queue: %{user_id() => :queue.queue(session_id())},
            waiters: %{session_id() => pid()},
            monitors: %{reference() => {user_id(), session_id()}},
            global_max: pos_integer(),
            per_user_max: pos_integer(),
            per_user_max_overrides: %{user_id() => pos_integer()}
          }
  end

  # --- API ---

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: @name)
  end

  @doc """
  Enqueue a session for execution. Always succeeds — the
  caller will receive `{:runner_slot, session_id}` when a
  slot opens. Returns position in the user's queue (0 if
  dispatched immediately).
  """
  @spec enqueue(String.t(), String.t(), pid()) ::
          {:ok, %{position: non_neg_integer()}}
  def enqueue(user_id, session_id, from_pid) when is_pid(from_pid) do
    GenServer.call(@name, {:enqueue, user_id, session_id, from_pid})
  end

  @doc """
  Release the slot held by `session_id` for `user_id`.
  Called on session exit. Triggers dispatch of the next
  queued session for that user.
  """
  @spec release(String.t(), String.t()) :: :ok
  def release(user_id, session_id) do
    GenServer.cast(@name, {:release, user_id, session_id})
  end

  @doc """
  Cancel a queued (or running) session. Removes it from
  the queue without dispatching, or frees its slot if
  already running.
  """
  @spec cancel(String.t(), String.t()) :: :ok
  def cancel(user_id, session_id) do
    GenServer.cast(@name, {:cancel, user_id, session_id})
  end

  @doc """
  Snapshot of current pool state, for the UI.
  """
  @spec snapshot() :: map()
  def snapshot, do: GenServer.call(@name, :snapshot)

  @doc """
  Bump the per-user cap for a specific user. Used by the
  future paid-tier flow.
  """
  @spec set_user_cap(String.t(), pos_integer()) :: :ok
  def set_user_cap(user_id, cap), do: GenServer.cast(@name, {:set_user_cap, user_id, cap})

  @doc """
  Re-check capacity and dispatch any eligible queued
  sessions. Useful after Reconciler rebuilds state or
  after a config change.
  """
  @spec tick() :: :ok
  def tick, do: GenServer.cast(@name, :tick)

  # --- GenServer ---

  @impl GenServer
  def init(_opts) do
    cfg = Application.fetch_env!(:camelot, :runner)

    state = %State{
      global_max: Keyword.get(cfg, :global_max, 20),
      per_user_max: Keyword.get(cfg, :per_user_max, 2)
    }

    {:ok, state}
  end

  @impl GenServer
  def handle_call({:enqueue, user_id, session_id, from_pid}, _from, state) do
    state =
      state
      |> add_waiter(session_id, from_pid)
      |> add_monitor(user_id, session_id, from_pid)
      |> enqueue_session(user_id, session_id)
      |> dispatch_user(user_id)

    position = queue_position(state, user_id, session_id)
    {:reply, {:ok, %{position: position}}, state}
  end

  def handle_call(:snapshot, _from, state) do
    per_user =
      state.active
      |> Map.keys()
      |> Enum.concat(Map.keys(state.queue))
      |> Enum.uniq()
      |> Map.new(fn uid ->
        active = active_count(state, uid)
        max = effective_cap(state, uid)
        queued = queued_count(state, uid)
        {uid, %{active: active, max: max, queued: queued}}
      end)

    snap = %{
      global: %{active: total_active(state), max: state.global_max},
      per_user: per_user
    }

    {:reply, snap, state}
  end

  @impl GenServer
  def handle_cast({:release, user_id, session_id}, state) do
    state =
      state
      |> remove_from_active(user_id, session_id)
      |> dispatch_global()

    broadcast(state)
    {:noreply, state}
  end

  def handle_cast({:cancel, user_id, session_id}, state) do
    state =
      state
      |> remove_from_active(user_id, session_id)
      |> remove_from_queue(user_id, session_id)
      |> drop_waiter(session_id)
      |> dispatch_global()

    broadcast(state)
    {:noreply, state}
  end

  def handle_cast({:set_user_cap, user_id, cap}, state) do
    overrides = Map.put(state.per_user_max_overrides, user_id, cap)
    state = %{state | per_user_max_overrides: overrides}
    {:noreply, dispatch_user(state, user_id)}
  end

  def handle_cast(:tick, state) do
    {:noreply, dispatch_global(state)}
  end

  @impl GenServer
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Map.pop(state.monitors, ref) do
      {nil, _} ->
        {:noreply, state}

      {{user_id, session_id}, monitors} ->
        state =
          %{state | monitors: monitors}
          |> remove_from_active(user_id, session_id)
          |> remove_from_queue(user_id, session_id)
          |> drop_waiter(session_id)
          |> dispatch_global()

        broadcast(state)
        {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # --- Internals ---

  defp add_waiter(state, session_id, pid) do
    %{state | waiters: Map.put(state.waiters, session_id, pid)}
  end

  defp drop_waiter(state, session_id) do
    %{state | waiters: Map.delete(state.waiters, session_id)}
  end

  defp add_monitor(state, user_id, session_id, pid) do
    ref = Process.monitor(pid)
    %{state | monitors: Map.put(state.monitors, ref, {user_id, session_id})}
  end

  defp enqueue_session(state, user_id, session_id) do
    q = Map.get(state.queue, user_id, :queue.new())
    %{state | queue: Map.put(state.queue, user_id, :queue.in(session_id, q))}
  end

  defp remove_from_active(state, user_id, session_id) do
    active = state.active

    case Map.get(active, user_id) do
      nil ->
        state

      set ->
        new_set = MapSet.delete(set, session_id)
        active = if MapSet.size(new_set) == 0, do: Map.delete(active, user_id), else: Map.put(active, user_id, new_set)
        %{state | active: active}
    end
  end

  defp remove_from_queue(state, user_id, session_id) do
    case Map.get(state.queue, user_id) do
      nil ->
        state

      q ->
        new_q = :queue.filter(fn id -> id != session_id end, q)

        queue =
          if :queue.is_empty(new_q) do
            Map.delete(state.queue, user_id)
          else
            Map.put(state.queue, user_id, new_q)
          end

        %{state | queue: queue}
    end
  end

  defp dispatch_user(state, user_id) do
    cond do
      total_active(state) >= state.global_max ->
        state

      active_count(state, user_id) >= effective_cap(state, user_id) ->
        state

      true ->
        case pop_queue(state, user_id) do
          {nil, state} ->
            state

          {session_id, state} ->
            grant(state, user_id, session_id)
            state |> add_active(user_id, session_id) |> drop_waiter(session_id)
        end
    end
  end

  defp dispatch_global(state) do
    state.queue
    |> Map.keys()
    |> Enum.reduce(state, fn user_id, acc -> dispatch_user(acc, user_id) end)
  end

  defp pop_queue(state, user_id) do
    case Map.get(state.queue, user_id) do
      nil -> {nil, state}
      q -> pop_from(state, user_id, :queue.out(q))
    end
  end

  defp pop_from(state, user_id, {:empty, _}) do
    {nil, %{state | queue: Map.delete(state.queue, user_id)}}
  end

  defp pop_from(state, user_id, {{:value, session_id}, new_q}) do
    {session_id, %{state | queue: replace_queue(state.queue, user_id, new_q)}}
  end

  defp replace_queue(queues, user_id, new_q) do
    if :queue.is_empty(new_q) do
      Map.delete(queues, user_id)
    else
      Map.put(queues, user_id, new_q)
    end
  end

  defp add_active(state, user_id, session_id) do
    set = Map.get(state.active, user_id, MapSet.new())
    %{state | active: Map.put(state.active, user_id, MapSet.put(set, session_id))}
  end

  defp grant(state, _user_id, session_id) do
    case Map.get(state.waiters, session_id) do
      nil ->
        Logger.warning("RunnerPool: no waiter for #{session_id}")

      pid ->
        send(pid, {:runner_slot, session_id})
    end
  end

  defp queue_position(state, user_id, session_id) do
    case Map.get(state.queue, user_id) do
      nil ->
        0

      q ->
        case Enum.find_index(:queue.to_list(q), &(&1 == session_id)) do
          nil -> 0
          n -> n + 1
        end
    end
  end

  defp total_active(state) do
    state.active
    |> Map.values()
    |> Enum.map(&MapSet.size/1)
    |> Enum.sum()
  end

  defp active_count(state, user_id) do
    state.active |> Map.get(user_id, MapSet.new()) |> MapSet.size()
  end

  defp queued_count(state, user_id) do
    case Map.get(state.queue, user_id) do
      nil -> 0
      q -> :queue.len(q)
    end
  end

  defp effective_cap(state, user_id) do
    Map.get(state.per_user_max_overrides, user_id, state.per_user_max)
  end

  defp broadcast(_state) do
    Phoenix.PubSub.broadcast(Camelot.PubSub, "runner_pool", :pool_changed)
  end
end
