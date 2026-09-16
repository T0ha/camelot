defmodule Camelot.Github.PullRequestApi do
  @moduledoc """
  Behaviour for the GitHub pull request write calls.

  Implemented by `Camelot.Github.Client`; selected through config so
  tests can swap in a stub, mirroring `Camelot.Board.AttachmentStore`
  and `Camelot.Runtime.Runner`:

      config :camelot, :github_pull_request_api, MyStub

  Only the write half of the PR surface lives here: the writes are the
  calls that must never reach github.com from a test, while the reads
  are already exercised against the live API by
  `Camelot.Github.ClientTest`. Widening the behaviour to the read calls
  (so PR polling can be driven entirely from fixtures) is a worthwhile
  follow-up, but it would touch every `Client` reader and is kept out
  of this change.
  """

  @typedoc "Options forwarded to the client (`installation_id:`, …)."
  @type opts :: keyword()

  @callback merge_pull_request(
              owner :: String.t(),
              repo :: String.t(),
              pr_number :: integer(),
              opts()
            ) :: {:ok, map()} | {:error, term()}

  @callback approve_pull_request(
              owner :: String.t(),
              repo :: String.t(),
              pr_number :: integer(),
              opts()
            ) :: {:ok, map()} | {:error, term()}

  @doc "Returns the configured pull request API implementation."
  @spec impl() :: module()
  def impl do
    Application.get_env(
      :camelot,
      :github_pull_request_api,
      Camelot.Github.Client
    )
  end
end
