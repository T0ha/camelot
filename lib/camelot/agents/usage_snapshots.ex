defmodule Camelot.Agents.UsageSnapshots do
  @moduledoc """
  Writing and reading `Camelot.Agents.UsageSnapshot`s.

  A snapshot is attributed to the credential a run used — the user's
  `Camelot.Accounts.Credential` of the agent's first required kind,
  the same row `Camelot.Runtime.TaskRunner.build_secrets/2` mounts —
  or, for a key supplied by env var, to the user and kind alone.

  ## Quota window

  Each credential kind is capped on one quota window — see
  `quota_window/1`. Claude Code and Codex plans are weekly; Kimi Code
  plans are monthly (its weekly quota only exists on legacy plans).

  ## Estimate

  Only `:cli` readings are live. A `:manual` reading (all Codex has
  until its rollout file is read) goes stale as soon as Camelot runs
  anything on that account, so `effective_quota/4` adds Camelot's own
  run time since the reading was taken, converted at
  `config :camelot, :scheduling, minutes_per_percent`, and labels the
  result `:estimated`. It cannot see manual use outside Camelot — the
  UI says so.
  """

  alias Camelot.Accounts.Credential
  alias Camelot.Agents.Session
  alias Camelot.Agents.UsageSnapshot
  alias Camelot.Runtime.RateLimitEvents

  require Ash.Query
  require Logger

  @default_minutes_per_percent 30

  @typedoc "A user id and the credential kind a snapshot is about."
  @type key :: {String.t(), atom()}

  @doc """
  Records one snapshot per window for `user_id`'s `kind` credential.

  Options: `:observed_at` (defaults to now).
  """
  @spec record(String.t(), atom(), [RateLimitEvents.window()], atom(), keyword()) ::
          {:ok, [UsageSnapshot.t()]} | {:error, term()}
  def record(user_id, kind, windows, source, opts \\ []) do
    base = %{
      user_id: user_id,
      credential_kind: kind,
      credential_id: credential_id(Credential.for_user_and_kind(user_id, kind)),
      source: source,
      observed_at: Keyword.get_lazy(opts, :observed_at, &DateTime.utc_now/0)
    }

    windows
    |> Enum.reduce_while({:ok, []}, fn window, {:ok, acc} ->
      case Ash.create(UsageSnapshot, Map.merge(window, base), action: :record, authorize?: false) do
        {:ok, snapshot} -> {:cont, {:ok, [snapshot | acc]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> then(fn
      {:ok, rows} -> {:ok, Enum.reverse(rows)}
      error -> error
    end)
  end

  @doc """
  The quota window the cap, the manual reading and the dispatch gate
  use for credentials of `kind`.
  """
  @spec quota_window(atom()) :: :weekly | :monthly
  def quota_window(:kimi_api_key), do: :monthly
  def quota_window(_kind), do: :weekly

  @doc """
  The latest snapshot of `kind`'s quota window (`quota_window/1`) for
  `user_id`'s credential, or `nil` when there is none or its window
  has already reset.
  """
  @spec latest_quota(String.t(), atom(), DateTime.t()) :: UsageSnapshot.t() | nil
  def latest_quota(user_id, kind, now) do
    credential = Credential.for_user_and_kind(user_id, kind)

    UsageSnapshot
    |> Ash.Query.for_read(:latest, %{
      user_id: user_id,
      credential_kind: kind,
      credential_id: credential_id(credential),
      window: quota_window(kind)
    })
    |> Ash.read_one!(authorize?: false)
    |> unless_stale(now)
  end

  @doc """
  `latest_quota/3` with the estimate applied to a `:manual` reading
  (see the moduledoc). A `:cli` reading is returned as is.
  """
  @spec effective_quota(String.t(), atom(), DateTime.t(), pos_integer()) ::
          UsageSnapshot.t() | nil
  def effective_quota(user_id, kind, now, minutes_per_percent \\ minutes_per_percent()) do
    user_id
    |> latest_quota(kind, now)
    |> with_estimate(minutes_per_percent)
  end

  @doc """
  `effective_quota/4` for many keys at once — what a dispatch tick
  needs — in one snapshot query (plus one credential lookup per key,
  the same lookup the runner makes).
  """
  @spec batch_latest([key()], DateTime.t()) :: %{key() => UsageSnapshot.t() | nil}
  def batch_latest([], _now), do: %{}

  def batch_latest(keys, now) do
    keys = Enum.uniq(keys)

    credentials =
      Map.new(keys, fn {user_id, kind} = key -> {key, credential_id(Credential.for_user_and_kind(user_id, kind))} end)

    user_ids = keys |> Enum.map(&elem(&1, 0)) |> Enum.uniq()

    snapshots =
      UsageSnapshot
      |> Ash.Query.filter(user_id in ^user_ids and window in [:weekly, :monthly] and resets_at > ^now)
      |> Ash.Query.sort(observed_at: :desc)
      |> Ash.read!(authorize?: false)

    minutes = minutes_per_percent()

    Map.new(keys, fn key ->
      {key,
       snapshots
       |> Enum.find(&belongs?(&1, key, Map.fetch!(credentials, key)))
       |> with_estimate(minutes)}
    end)
  end

  @doc "Configured run minutes that count as one quota percent."
  @spec minutes_per_percent() :: pos_integer()
  def minutes_per_percent do
    :camelot
    |> Application.get_env(:scheduling, [])
    |> Keyword.get(:minutes_per_percent, @default_minutes_per_percent)
  end

  defp credential_id(%Credential{id: id}), do: id
  defp credential_id(nil), do: nil

  defp belongs?(snapshot, {_user_id, kind} = key, credential_id) do
    snapshot.window == quota_window(kind) and owned?(snapshot, key, credential_id)
  end

  defp owned?(snapshot, {user_id, kind}, nil) do
    is_nil(snapshot.credential_id) and snapshot.user_id == user_id and
      snapshot.credential_kind == kind
  end

  defp owned?(snapshot, _key, credential_id), do: snapshot.credential_id == credential_id

  defp unless_stale(nil, _now), do: nil

  defp unless_stale(%UsageSnapshot{resets_at: resets_at} = snapshot, now) do
    current(DateTime.after?(resets_at, now), snapshot)
  end

  defp current(true, snapshot), do: snapshot
  defp current(false, _snapshot), do: nil

  defp with_estimate(%UsageSnapshot{source: :manual} = snapshot, minutes_per_percent) do
    snapshot
    |> run_ms_since()
    |> estimated(snapshot, minutes_per_percent)
  end

  defp with_estimate(snapshot, _minutes_per_percent), do: snapshot

  defp estimated(0, snapshot, _minutes_per_percent), do: snapshot

  defp estimated(run_ms, snapshot, minutes_per_percent) do
    added = run_ms / 60_000 / minutes_per_percent
    used = (snapshot.used_percent + added) |> min(100.0) |> Float.round(2)

    %{snapshot | used_percent: used, source: :estimated}
  end

  # Camelot's own run time on this account since the manual reading:
  # finished sessions of this user whose agent mounts the same kind.
  defp run_ms_since(%UsageSnapshot{user_id: user_id, credential_kind: kind, observed_at: observed_at}) do
    Session
    |> Ash.Query.filter(user_id == ^user_id and finished_at >= ^observed_at and not is_nil(duration_ms))
    |> Ash.Query.load(:agent)
    |> Ash.read!(authorize?: false)
    |> Enum.filter(&(primary_kind(&1.agent) == kind))
    |> Enum.map(& &1.duration_ms)
    |> Enum.sum()
  end

  defp primary_kind(%{required_credential_kinds: [kind | _]}), do: kind
  defp primary_kind(_agent), do: nil
end
