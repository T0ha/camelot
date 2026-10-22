defmodule CamelotWeb.UsageScheduling do
  @moduledoc """
  Web-side helpers for usage-aware scheduling, shared by the profile's
  "Usage limits" section, the task page's schedule popover and the
  board's badges.

  `window_rows/1` is the weekday + from/to editor both forms render
  (built from the stock `<.input>`); everything else turns form params
  and stored UTC values into what the user sees and back, through
  `Camelot.TimeZone`.
  """
  use Phoenix.Component

  import CamelotWeb.CoreComponents, only: [input: 1]

  alias Camelot.TimeZone
  alias Phoenix.LiveView.Rendered

  @days [{1, "Mon"}, {2, "Tue"}, {3, "Wed"}, {4, "Thu"}, {5, "Fri"}, {6, "Sat"}, {7, "Sun"}]

  @blank_row %{days: [], from: "", to: ""}

  attr :id, :string, required: true
  attr :name, :string, required: true, doc: ~s|param prefix, e.g. "policy[windows]"|
  attr :rows, :list, required: true, doc: "local rows; a trailing blank row adds one"

  @doc """
  The run-window editor: one line per local row, each with weekday
  checkboxes and from/to times. A row with no day ticked is ignored on
  save, which is how a row is removed.
  """
  @spec window_rows(map()) :: Rendered.t()
  def window_rows(assigns) do
    assigns = assign(assigns, :days, @days)

    ~H"""
    <div id={@id} class="space-y-1">
      <div
        :for={{row, index} <- Enum.with_index(@rows)}
        id={"#{@id}-#{index}"}
        class="flex flex-wrap items-end gap-x-2"
      >
        <.input
          :for={{day, label} <- @days}
          type="checkbox"
          id={"#{@id}-#{index}-d#{day}"}
          name={"#{@name}[#{index}][d#{day}]"}
          value={day in row.days}
          label={label}
        />
        <.input
          type="time"
          id={"#{@id}-#{index}-from"}
          name={"#{@name}[#{index}][from]"}
          value={row.from}
          label="From"
          class="input input-sm"
        />
        <.input
          type="time"
          id={"#{@id}-#{index}-to"}
          name={"#{@name}[#{index}][to]"}
          value={row.to}
          label="To"
          class="input input-sm"
        />
      </div>
    </div>
    """
  end

  @doc "Editor rows for `windows` in `zone`, plus a blank row to add one."
  @spec editor_rows([Camelot.Agents.RunWindow.t()] | nil, String.t(), DateTime.t()) ::
          [TimeZone.row()]
  def editor_rows(windows, zone, now) do
    (windows || [])
    |> TimeZone.windows_to_rows(zone, now)
    |> Enum.concat([@blank_row])
  end

  @doc """
  Reads the editor's params back into UTC window attribute maps, ready
  for an Ash `{:array, RunWindow}` attribute.
  """
  @spec windows_from_params(map() | nil, String.t(), DateTime.t()) :: [map()]
  def windows_from_params(params, zone, now) do
    params
    |> rows_from_params()
    |> TimeZone.rows_to_windows(zone, now)
    |> Enum.map(&Map.take(&1, [:start_minute, :end_minute]))
  end

  @doc "A blank-tolerant integer param: `\"\"`/nil/garbage is nil."
  @spec parse_integer(String.t() | nil) :: integer() | nil
  def parse_integer(value) do
    case Integer.parse(to_string(value)) do
      {integer, ""} -> integer
      _blank_or_invalid -> nil
    end
  end

  @doc "A blank-tolerant percentage param, clamped to 0..100."
  @spec parse_percent(String.t() | nil) :: float() | nil
  def parse_percent(value) do
    case Float.parse(to_string(value)) do
      {percent, ""} -> percent |> max(0.0) |> min(100.0)
      _blank_or_invalid -> nil
    end
  end

  @doc ~S|`23.0` → `"23%"`, `6.5` → `"6.5%"`.|
  @spec format_percent(number()) :: String.t()
  def format_percent(percent) do
    rounded = Float.round(percent * 1.0, 1)
    percent_label(rounded, rounded == Float.round(rounded))
  end

  defp percent_label(rounded, true), do: "#{trunc(rounded)}%"
  defp percent_label(rounded, false), do: "#{rounded}%"

  @doc """
  The badge line for a card's `scheduled_wait` (see
  `Camelot.Board.Task.Calculations.ScheduledWait`), or nil.
  """
  @spec badge_text(map() | nil, map(), String.t()) :: String.t() | nil
  def badge_text(%{reason: :cap, until: until}, _task, zone),
    do: "Weekly cap reached — resumes #{TimeZone.format(until, zone)}"

  def badge_text(%{reason: :window, until: until}, _task, zone),
    do: "Outside run window — opens #{TimeZone.format(until, zone)}"

  def badge_text(%{reason: :start_at, until: until}, _task, zone), do: "Starts #{TimeZone.format(until, zone)}"

  def badge_text(%{flag: :promoted}, task, zone), do: "Promoted — deadline #{TimeZone.format(task.deadline_at, zone)}"

  def badge_text(%{flag: :at_risk}, task, zone), do: "At risk — deadline #{TimeZone.format(task.deadline_at, zone)}"

  def badge_text(%{flag: :reserve_risk}, _task, _zone), do: "Over weekly cap — running anyway"
  def badge_text(_wait, _task, _zone), do: nil

  @doc "daisyUI badge class for a `scheduled_wait`."
  @spec badge_class(map()) :: String.t()
  def badge_class(%{flag: :at_risk}), do: "badge-error"
  def badge_class(%{flag: flag}) when flag in [:promoted, :reserve_risk], do: "badge-warning"
  def badge_class(_wait), do: "badge-ghost"

  defp rows_from_params(nil), do: []

  defp rows_from_params(params) do
    params
    |> Enum.sort_by(fn {index, _row} -> parse_integer(index) || 0 end)
    |> Enum.map(fn {_index, row} -> row_from_params(row) end)
  end

  defp row_from_params(row) do
    %{
      days: for({day, _label} <- @days, row["d#{day}"] == "true", do: day),
      from: row["from"] || "",
      to: row["to"] || ""
    }
  end
end
