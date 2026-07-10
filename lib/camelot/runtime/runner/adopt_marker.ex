defmodule Camelot.Runtime.Runner.AdoptMarker do
  @moduledoc """
  The exec-wrapper writes the agent's exit code to a per-session
  marker file (`/tmp/camelot-exit-<session_id>`) once the run
  finishes. After a Camelot restart the original `docker exec` id is
  gone, so an adopting session can't poll the exec for its status — it
  polls for this marker instead, then reads the tee'd output file.

  Written last by the wrapper, so the marker's presence strictly implies
  the output file (`/tmp/camelot-output-<session_id>.log`) is complete.
  """

  @doc "Absolute path of the completion marker for a session."
  @spec path(String.t()) :: String.t()
  def path(session_id), do: "/tmp/camelot-exit-#{session_id}"

  @doc """
  Parses marker file contents into an exit code.

  Returns `:none` for empty/absent (a `cat` of a missing file yields
  empty stdout) or non-numeric content, so the poller keeps waiting.
  """
  @spec parse(binary() | term()) :: {:ok, integer()} | :none
  def parse(body) when is_binary(body) do
    case body |> String.trim() |> Integer.parse() do
      {code, _rest} -> {:ok, code}
      :error -> :none
    end
  end

  def parse(_), do: :none
end
