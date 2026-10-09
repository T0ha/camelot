defmodule Camelot.Support.StubModelApi do
  @moduledoc """
  Test stub for `Camelot.Agents.ModelApi`.

  Configured as the default implementation in `config/test.exs`, so no
  test can reach a provider over the network. Uninstalled, it answers
  an empty listing — which, under `Camelot.Agents.ModelDiscovery`'s
  "discovered wins, pinned is the fallback" rule, leaves every test
  that doesn't care about discovery seeing the agent's seeded
  `available_models`.

  `install/1` records the canned reply plus the test pid in
  application env — not the process dictionary — because the code
  under test usually runs in another process (a LiveView). Every call
  messages the test process, so assertions can check exactly what
  would have been sent, headers included, and can prove a second call
  was served from the cache by asserting no second message.
  """

  @behaviour Camelot.Agents.ModelApi

  @env_key :stub_model_api

  @empty {:ok, %{"data" => []}}

  @doc """
  Installs canned replies, optionally per URL.

  `reply:` sets the single reply every call returns; `replies:` takes a
  `%{url => reply}` map for tests that probe two providers in one run.
  Both are in the behaviour's `{:ok, map()} | {:error, term()}` shape.
  Pair with `uninstall/0` in an `on_exit` callback.
  """
  @spec install(keyword()) :: :ok
  def install(opts \\ []) do
    Application.put_env(:camelot, @env_key, %{
      test_pid: self(),
      reply: Keyword.get(opts, :reply, @empty),
      replies: Keyword.get(opts, :replies, %{})
    })

    Application.put_env(:camelot, :model_api, __MODULE__)
  end

  @doc "Restores the empty-listing default."
  @spec uninstall() :: :ok
  def uninstall do
    Application.put_env(:camelot, :model_api, __MODULE__)
    Application.delete_env(:camelot, @env_key)
  end

  @impl true
  def list_models(url, headers) do
    :camelot
    |> Application.get_env(@env_key)
    |> reply(url, headers)
  end

  # Not installed: no test pid to message, and an empty catalog.
  defp reply(nil, _url, _headers), do: @empty

  defp reply(config, url, headers) do
    send(config.test_pid, {:list_models, url, headers})

    Map.get(config.replies, url, config.reply)
  end
end
