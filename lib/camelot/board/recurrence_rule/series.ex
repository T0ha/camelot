defmodule Camelot.Board.RecurrenceRule.Series do
  @moduledoc """
  The cards of a recurring series: finding the latest one, and what
  the next one copies from it.

  Plain functions behind `Camelot.Board.RecurrenceRule`'s change
  modules, kept out of the resource itself.
  """

  alias Camelot.Board.RecurrenceRule
  alias Camelot.Board.Task
  alias Camelot.Scheduling.Recurrence

  require Ash.Query

  # Everything a spawned card copies verbatim from the latest card.
  @copied_fields [
    :title,
    :description,
    :priority,
    :next_model,
    :weekly_cap_override,
    :windows_override,
    :ignore_limits,
    :project_id,
    :agent_id,
    :creator_id
  ]

  @doc "The newest card of the series `rule_id`, if any is left."
  @spec latest_task(Ecto.UUID.t()) :: {:ok, Task.t()} | {:error, :no_task}
  def latest_task(rule_id) do
    Task
    |> Ash.Query.filter(recurrence_rule_id == ^rule_id)
    |> Ash.Query.sort(inserted_at: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read_one(authorize?: false)
    |> found()
  end

  @doc """
  `Task` `:create` input for the card that follows `latest` at
  `start_at`. A deadline keeps its offset from the start.
  """
  @spec next_task_attrs(Task.t(), RecurrenceRule.t(), DateTime.t()) :: map()
  def next_task_attrs(latest, rule, start_at) do
    latest
    |> Map.take(@copied_fields)
    |> Map.merge(%{
      start_at: start_at,
      deadline_at: shift_deadline(latest, start_at),
      skip_planning: rule.skip_planning,
      recurrence_rule_id: rule.id
    })
  end

  @doc """
  `:ok` when `occurrence` is within the series' "repeat until".
  """
  @spec before_end(DateTime.t(), DateTime.t() | nil) :: :ok | {:error, :past_end}
  def before_end(_occurrence, nil), do: :ok

  def before_end(occurrence, ends_at) do
    if DateTime.after?(occurrence, ends_at) do
      {:error, :past_end}
    else
      :ok
    end
  end

  @doc """
  The `Camelot.Scheduling.Recurrence` view of a rule being saved,
  read from the changeset so unsaved edits count.
  """
  @spec rule_from_changeset(Ash.Changeset.t()) :: Recurrence.rule()
  def rule_from_changeset(changeset) do
    [:frequency, :interval, :weekdays, :day_of_month, :time_of_day, :time_zone, :ends_at]
    |> Map.new(&{&1, Ash.Changeset.get_attribute(changeset, &1)})
    |> Map.put(:inserted_at, changeset.data.inserted_at)
  end

  defp found({:ok, %Task{} = task}), do: {:ok, task}
  defp found(_none), do: {:error, :no_task}

  defp shift_deadline(%Task{start_at: %DateTime{} = start, deadline_at: %DateTime{} = deadline}, start_at) do
    DateTime.add(start_at, DateTime.diff(deadline, start, :microsecond), :microsecond)
  end

  defp shift_deadline(_latest, _start_at), do: nil
end
