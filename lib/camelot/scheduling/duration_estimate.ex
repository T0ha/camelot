defmodule Camelot.Scheduling.DurationEstimate do
  @moduledoc """
  How long a card's next run is expected to take, for deadline
  promotion in `Camelot.Scheduling.Gate`.

  The 80th percentile of the last 50 completed sessions for the
  same agent and stage — p80 rather than the mean, so a deadline is
  defended against a typically slow run, not an average one. Falls
  back to `config :camelot, :scheduling, duration_fallback_minutes`
  until a pair has any history.
  """

  alias Camelot.Agents.Session

  require Ash.Query

  @sample_size 50
  @percentile 0.8
  @default_fallback_minutes 30

  @typedoc "An agent id and the stage its next run is for."
  @type key :: {String.t(), atom()}

  @doc """
  The stage a queued card's next run is for: a `:todo` card is
  dispatched straight into planning (see `Task`'s `:begin_work`).
  """
  @spec next_stage(atom()) :: atom()
  def next_stage(:todo), do: :planning
  def next_stage(stage), do: stage

  @doc "Estimates for every key, in one query per distinct key."
  @spec estimates([key()]) :: %{key() => pos_integer()}
  def estimates(keys) do
    keys
    |> Enum.uniq()
    |> Map.new(&{&1, estimate_ms(&1)})
  end

  @doc "The p80 run length in milliseconds for `{agent_id, stage}`."
  @spec estimate_ms(key()) :: pos_integer()
  def estimate_ms({agent_id, stage}) do
    Session
    |> Ash.Query.filter(
      agent_id == ^agent_id and stage == ^stage and status == :completed and
        not is_nil(duration_ms)
    )
    |> Ash.Query.sort(inserted_at: :desc)
    |> Ash.Query.limit(@sample_size)
    |> Ash.Query.select([:duration_ms])
    |> Ash.read!(authorize?: false)
    |> Enum.map(& &1.duration_ms)
    |> percentile()
  end

  @doc "The configured fallback, in milliseconds."
  @spec fallback_ms() :: pos_integer()
  def fallback_ms do
    :camelot
    |> Application.get_env(:scheduling, [])
    |> Keyword.get(:duration_fallback_minutes, @default_fallback_minutes)
    |> Kernel.*(60_000)
  end

  defp percentile([]), do: fallback_ms()

  defp percentile(durations) do
    sorted = Enum.sort(durations)
    index = ceil(length(sorted) * @percentile) - 1
    Enum.at(sorted, index)
  end
end
