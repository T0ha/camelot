defmodule CamelotWeb.Plugs.RequestContext do
  @moduledoc """
  Starts every request with process state that describes only *this*
  request.

  Two things this application leans on for attribution live in the
  process dictionary: the `Logger` metadata behind the JSON logs'
  `user_id` / `project_id` / `task_id` fields, and the `PostHog`
  context behind a capture's `$current_url`. A LiveView's connected
  process is its own, but its dead render runs in the connection
  process — and Bandit keeps one process per TCP connection, looping
  over every keep-alive request on it
  (`Bandit.HTTP1.Handler.handle_data/3`).

  Neither Plug, Phoenix nor LiveView clears either between those
  requests, and `PostHog.Context` has no delete at all: it only ever
  merges. So the last page a browser loaded would otherwise tag
  everything it asked for afterwards — a GitHub connect failure filed
  under whichever task the user happened to look at first, an
  anonymous request still carrying the id of a user who has signed
  out. Wrong attribution, which is worse than none.

  Runs before `PostHog.Integrations.Plug`, which repopulates the
  context for the request actually in hand.
  """

  require Logger

  # Written with `Logger.metadata/1` — and so inherited by everything
  # the process logs afterwards — by `CamelotWeb.LiveUserAuth` and
  # `CamelotWeb.TaskLive`. Keys passed per call site
  # (`reason`, `http_status`, `installation_id`) never persist.
  @process_scoped [:user_id, :project_id, :task_id]

  @spec init(keyword()) :: keyword()
  def init(opts), do: opts

  @spec call(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def call(conn, _opts) do
    Logger.metadata(cleared())

    conn
  end

  # The PostHog context is one opaque `Logger` metadata key, so
  # clearing it clears every scope at once. Taken from the library
  # rather than written out, so a rename fails the build instead of
  # silently leaving the leak in place.
  @spec cleared() :: keyword()
  defp cleared do
    for key <- [PostHog.Context.logger_metadata_key() | @process_scoped], do: {key, nil}
  end
end
