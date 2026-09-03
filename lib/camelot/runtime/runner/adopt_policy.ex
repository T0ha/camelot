defmodule Camelot.Runtime.Runner.AdoptPolicy do
  @moduledoc """
  Pure decision shared by both container backends: should an adoption
  keep polling for the exec-wrapper's completion marker, or give up?

  Adoption re-attaches to a run that survived a Camelot restart by
  polling `/tmp/camelot-exit-<session_id>` inside the runner container.
  That poll **must** be bounded. If the container was replaced after the
  session's exec began — a Swarm reschedule, an OOM kill, or the boot
  sweep rolling the service onto a newer image — the marker lived in the
  prior container's `/tmp` and can never appear. An unbounded poll would
  strand the session `:running` and its task in `executing` forever.

  Two independent give-up conditions:

    * `:container_replaced` — the live container started strictly after
      the session's exec did, so the marker is provably gone. Checked on
      every poll iteration, not just at adoption start: a deploy can
      replace the container *while* the adoption is already running.
    * `:timeout` — the wall-clock budget expired. A backstop for missing
      or skewed timestamps, where the first check can't conclude
      anything.
  """

  @doc """
  Default wall-clock budget for an adoption poll. Comfortably exceeds
  any real re-attach settle time, while still bounding the case where
  container timestamps are unavailable.
  """
  @spec budget_ms() :: pos_integer()
  def budget_ms, do: 900_000

  @doc """
  Whether to keep polling, or give up and why.

  ## Examples

      iex> alias Camelot.Runtime.Runner.AdoptPolicy
      iex> AdoptPolicy.decide(nil, nil, 0, 1000)
      :poll
      iex> AdoptPolicy.decide(nil, nil, 1000, 1000)
      {:give_up, :timeout}
  """
  @spec decide(
          DateTime.t() | nil,
          DateTime.t() | nil,
          non_neg_integer(),
          non_neg_integer()
        ) :: :poll | {:give_up, :container_replaced | :timeout}
  def decide(container_started_at, session_started_at, elapsed_ms, budget_ms) do
    cond do
      container_replaced?(container_started_at, session_started_at) ->
        {:give_up, :container_replaced}

      elapsed_ms >= budget_ms ->
        {:give_up, :timeout}

      true ->
        :poll
    end
  end

  @doc """
  True when the runner container started strictly after the session's
  exec did — proof that the completion marker (and the tee'd output the
  adoption would read) no longer exist.

  Either timestamp being unknown yields `false`: the caller then falls
  back to the wall-clock budget rather than abandoning a run that may
  still be perfectly healthy.
  """
  @spec container_replaced?(DateTime.t() | nil, DateTime.t() | nil) :: boolean()
  def container_replaced?(%DateTime{} = container_started, %DateTime{} = session_started) do
    DateTime.after?(container_started, session_started)
  end

  def container_replaced?(_container_started, _session_started), do: false

  @doc """
  Human-readable explanation of a give-up reason, used as the session's
  error message and in the re-queue log line.
  """
  @spec reason_message(:container_replaced | :timeout) :: String.t()
  def reason_message(:container_replaced) do
    "the runner container was replaced while the run was in flight, " <>
      "so its result could not be recovered"
  end

  def reason_message(:timeout) do
    "the runner did not report a result within the re-attach budget " <>
      "after Camelot restarted"
  end
end
