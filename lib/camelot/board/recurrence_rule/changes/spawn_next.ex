defmodule Camelot.Board.RecurrenceRule.Changes.SpawnNext do
  @moduledoc """
  The `:spawn_next` trigger's work: create the series' next card.

  The trigger only fires for an enabled rule with no open card, so
  this always creates at most one card — for the first occurrence
  **after now**, never for the slots missed while the previous card
  was open. The card is an ordinary `Task` `:create` copied from the
  latest card (`Camelot.Board.RecurrenceRule.Series.next_task_attrs/3`),
  so its validations, notifiers and telemetry all apply.

  The rule turns itself off instead when the series cannot go on: no
  card left to copy, its agent gone, the next occurrence past
  `ends_at`, or a next card `Task` would refuse (e.g. a model the
  agent no longer offers). A disabled rule is never picked up again,
  so it cannot fail every minute.
  """
  use Ash.Resource.Change

  alias Camelot.Agents.Agent
  alias Camelot.Board.RecurrenceRule.Series
  alias Camelot.Board.Task
  alias Camelot.Scheduling.Recurrence

  require Logger

  @impl true
  @spec change(Ash.Changeset.t(), keyword(), Ash.Resource.Change.Context.t()) ::
          Ash.Changeset.t()
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, &spawn_card/1)
  end

  defp spawn_card(%Ash.Changeset{data: rule} = changeset) do
    with {:ok, latest} <- Series.latest_task(rule.id),
         :ok <- agent_exists(latest.agent_id),
         {:ok, next} <- Recurrence.next_occurrence(rule, DateTime.utc_now()),
         :ok <- Series.before_end(next, rule.ends_at),
         {:ok, notifications} <- create_card(Series.next_task_attrs(latest, rule, next)) do
      {Ash.Changeset.force_change_attribute(changeset, :next_run_at, next), %{notifications: notifications}}
    else
      {:error, reason} -> disable(changeset, reason)
    end
  end

  defp agent_exists(nil), do: {:error, :no_agent}

  defp agent_exists(agent_id) do
    case Ash.get(Agent, agent_id, authorize?: false) do
      {:ok, _agent} -> :ok
      {:error, _reason} -> {:error, :no_agent}
    end
  end

  # Validated up front so a refusal disables the rule instead of
  # failing — and rolling back — the transaction it runs in.
  defp create_card(attrs) do
    Task
    |> Ash.Changeset.for_create(:create, attrs, authorize?: false)
    |> create_valid()
  end

  defp create_valid(%Ash.Changeset{valid?: false}), do: {:error, :invalid_card}

  defp create_valid(changeset) do
    case Ash.create(changeset, return_notifications?: true) do
      {:ok, _task, notifications} -> {:ok, notifications}
      {:error, _error} -> {:error, :invalid_card}
    end
  end

  defp disable(changeset, reason) do
    Logger.info("Recurring series stopped", recurrence_rule_id: changeset.data.id, reason: reason)

    changeset
    |> Ash.Changeset.force_change_attribute(:enabled, false)
    |> Ash.Changeset.force_change_attribute(:next_run_at, nil)
  end
end
