defmodule Camelot.Agents.ModelApi do
  @moduledoc """
  Behaviour for the provider "list models" HTTP call.

  Implemented by `Camelot.Agents.ModelApi.Http`; selected through
  config so tests can swap in a stub, mirroring
  `Camelot.Github.PullRequestApi`:

      config :camelot, :model_api, MyStub

  One callback, because that is the whole surface
  `Camelot.Agents.ModelDiscovery` needs: a GET whose headers already
  carry the user's credential. Keeping the credential in the caller
  means the stub never has to hold a secret, and the behaviour stays
  provider-agnostic — Anthropic and OpenAI differ only in the URL and
  the headers.
  """

  @typedoc "Request headers, credential included."
  @type headers :: [{String.t(), String.t()}]

  @callback list_models(url :: String.t(), headers()) ::
              {:ok, map()} | {:error, term()}

  @doc "Returns the configured model listing implementation."
  @spec impl() :: module()
  def impl do
    Application.get_env(:camelot, :model_api, Camelot.Agents.ModelApi.Http)
  end
end
