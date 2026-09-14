defmodule Camelot.Github.PullRequestApi do
  @moduledoc """
  Behaviour for the GitHub pull request write calls.

  Implemented by `Camelot.Github.Client`; selected through config so
  tests can swap in a stub, mirroring `Camelot.Board.AttachmentStore`
  and `Camelot.Runtime.Runner`:

      config :camelot, :github_pull_request_api, MyStub

  Only the write half of the PR surface lives here — the read calls
  are plain `Client` functions, since nothing needs to fake them.
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
