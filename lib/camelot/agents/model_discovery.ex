defmodule Camelot.Agents.ModelDiscovery do
  @moduledoc """
  Resolves which models an agent CLI may use **for one user**, by
  asking the provider with that user's own credential.

  `Camelot.Agents.Agent.available_models` is a global, hand-maintained
  column, and the valid set is neither global nor stable: it is scoped
  to the credential that will run the task (an API key and a ChatGPT
  subscription are entitled to different ids, and new ids ship between
  releases). Both providers answer the question with one free GET —
  `GET https://api.anthropic.com/v1/models`,
  `GET https://api.openai.com/v1/models` — so the dropdown asks rather
  than guesses.

  Precedence is "discovered wins, pinned is the fallback":
  `models_for/2` returns a successful non-empty probe, and otherwise
  exactly `available_models`. The fallback covers every degraded case
  — no probe configured, no credential held, provider down, an answer
  that filtered down to nothing — so this module can only ever add
  options the user is entitled to, never take the pinned ones away.

  ## Caching

  Answers are memoised in `Camelot.Cache` under
  `{:model_discovery, user_id, digest}`, where `digest` covers the
  agent's `models_probe` map *and* the credential value. Rotating or
  deleting a key, or editing the probe at `/agents`, therefore
  invalidates the entry by construction — there is no eviction hook to
  keep in sync anywhere. `user_id` is in the key as well, so one
  user's entitlements are never served to another. The secret itself is
  in neither the key nor the value: only its digest.

  A successful list is held for an hour, a failure for a minute (see
  `:model_discovery` in `config/config.exs`), so a dead provider can't
  cost a request timeout on every board render while a user who fixes
  their key recovers promptly.

  Reading the credential happens *before* the cache lookup, because
  the digest depends on it. That is a local indexed read plus a
  decrypt — cheap next to the HTTP call it is protecting, and the
  reason a warm dropdown render does no network I/O at all.
  """

  alias Camelot.Accounts.Credential
  alias Camelot.Agents.Agent
  alias Camelot.Agents.ModelApi
  alias Camelot.Cache
  alias Camelot.Telemetry.Capture
  alias Camelot.Telemetry.Reason

  require Logger

  @typedoc """
  A normalised `models_probe` map: the fields this module reads, with
  the optional ones defaulted and the credential kind resolved to the
  atom `Camelot.Accounts.Credential` stores.
  """
  @type probe :: %{
          url: String.t(),
          auth: String.t(),
          kind: atom(),
          list_key: String.t(),
          id_key: String.t(),
          include: String.t() | nil
        }

  @typedoc "Why a probe produced no list of its own."
  @type error :: :no_probe | :no_credential | Reason.reason()

  # Anthropic requires a version header on every request, and rejects
  # an OAuth access token on `x-api-key` — the same split
  # `Camelot.Runtime.Runner.SecretEnv.to_env/1` encodes for the runner.
  @anthropic_version "2023-06-01"
  @anthropic_oauth_beta "oauth-2025-04-20"

  @auth_strategies ["anthropic", "bearer"]

  @doc """
  The models to offer `user_id` for `agent`: the discovered list when
  there is one, else the agent's pinned `available_models`.

  The one function both the task form and
  `Camelot.Board.Task`'s `next_model` validation call, so the set a
  user is offered and the set the changeset accepts cannot drift.
  """
  @spec models_for(Agent.t() | nil, String.t() | nil) :: [String.t()]
  def models_for(agent, user_id) do
    case for_user(agent, user_id) do
      {:ok, [_ | _] = models} -> models
      _degraded -> pinned(agent)
    end
  end

  @doc """
  Asks the provider which models `user_id`'s credential may use.

  Returns `{:error, :no_probe}` when the agent has no (usable)
  `models_probe`, `{:error, :no_credential}` when the user holds no key
  of the kind it names, and a classified `t:Camelot.Telemetry.Reason.reason/0`
  when the call itself failed. Callers that just want a dropdown want
  `models_for/2`; this is for the `/agents` "Check models" action,
  which has to say *why* nothing came back.
  """
  @spec for_user(Agent.t() | nil, String.t() | nil) ::
          {:ok, [String.t()]} | {:error, error()}
  def for_user(nil, _user_id), do: {:error, :no_probe}

  def for_user(%Agent{models_probe: nil}, _user_id), do: {:error, :no_probe}

  def for_user(%Agent{models_probe: config}, user_id) do
    with {:ok, probe} <- probe_config(config),
         {:ok, value} <- credential_value(probe, user_id) do
      cached_models(config, probe, user_id, value)
    end
  end

  @spec pinned(Agent.t() | nil) :: [String.t()]
  defp pinned(%Agent{available_models: models}), do: models
  defp pinned(_agent), do: []

  # An admin edits `models_probe` as free-form JSON, so every field is
  # validated here rather than trusted: a map missing `url`/`auth`/
  # `credential_kind`, or naming a kind/auth strategy this app doesn't
  # implement, is a probe that cannot run — reported as "not
  # configured" so the dropdown degrades to the pinned list instead of
  # raising mid-render.
  @spec probe_config(map()) :: {:ok, probe()} | {:error, :no_probe}
  defp probe_config(%{"url" => url, "auth" => auth, "credential_kind" => kind} = config) when auth in @auth_strategies do
    kind
    |> credential_kind()
    |> build_probe(url, auth, config)
  end

  defp probe_config(_config), do: {:error, :no_probe}

  @spec build_probe(atom() | nil, String.t(), String.t(), map()) ::
          {:ok, probe()} | {:error, :no_probe}
  defp build_probe(nil, _url, _auth, _config), do: {:error, :no_probe}

  defp build_probe(kind, url, auth, config) do
    {:ok,
     %{
       url: url,
       auth: auth,
       kind: kind,
       list_key: Map.get(config, "list_key", "data"),
       id_key: Map.get(config, "id_key", "id"),
       include: pattern(Map.get(config, "include"))
     }}
  end

  # `"" <> value` matches any binary: an `include` an admin typed as a
  # number (or a list) is no pattern at all, and must not reach
  # `Regex.compile/1`.
  @spec pattern(term()) :: String.t() | nil
  defp pattern("" <> value), do: value
  defp pattern(_other), do: nil

  # `String.to_existing_atom/1` on admin-supplied JSON would raise on a
  # typo (and `String.to_atom/1` leaks), so the kind is matched against
  # the resource's own list instead.
  @spec credential_kind(term()) :: atom() | nil
  defp credential_kind(kind) do
    Enum.find(Credential.valid_kinds(), &(to_string(&1) == kind))
  end

  @spec credential_value(probe(), String.t() | nil) ::
          {:ok, String.t()} | {:error, :no_credential}
  defp credential_value(_probe, nil), do: {:error, :no_credential}

  defp credential_value(%{kind: kind}, user_id) do
    user_id
    |> Credential.for_user_and_kind(kind, load_value?: true)
    |> credential_result(kind, user_id)
  end

  # Not holding the key yet is the ordinary state of a user who hasn't
  # reached `/profile`, not a fault: info, and no PostHog event, since
  # this is on the path of every board render.
  @spec credential_result(Credential.t() | nil, atom(), String.t()) ::
          {:ok, String.t()} | {:error, :no_credential}
  defp credential_result(nil, kind, user_id) do
    Logger.info("Model discovery skipped: no #{kind} credential", user_id: user_id)

    {:error, :no_credential}
  end

  defp credential_result(%Credential{value: value}, _kind, _user_id), do: {:ok, value}

  @spec cached_models(map(), probe(), String.t(), String.t()) ::
          {:ok, [String.t()]} | {:error, Reason.reason()}
  defp cached_models(config, probe, user_id, value) do
    key = cache_key(config, user_id, value)

    case cached(key) do
      nil -> fetch_and_cache(key, probe, user_id, value)
      result -> result
    end
  end

  # A cache fault must never break the dropdown, so an error reads as a
  # miss: worst case the provider is asked again.
  @spec cached(tuple()) :: {:ok, [String.t()]} | {:error, Reason.reason()} | nil
  defp cached(key) do
    case Cache.get(key) do
      {:ok, result} -> result
      {:error, _reason} -> nil
    end
  end

  @spec fetch_and_cache(tuple(), probe(), String.t(), String.t()) ::
          {:ok, [String.t()]} | {:error, Reason.reason()}
  defp fetch_and_cache(key, probe, user_id, value) do
    result = probe_models(probe, user_id, value)

    _ = Cache.put(key, result, ttl: ttl(result))

    result
  end

  # The digest covers the whole `models_probe` map, not just the fields
  # read above, so any edit at `/agents` takes effect on the next
  # render; and the credential value, so a rotation does too. The
  # secret is never stored — `:crypto.hash/2` is one-way and the probe
  # result holds no secret of its own.
  @spec cache_key(map(), String.t(), String.t()) :: tuple()
  defp cache_key(config, user_id, value) do
    digest = :crypto.hash(:sha256, :erlang.term_to_binary({config, value}))

    {:model_discovery, user_id, digest}
  end

  @spec ttl({:ok, [String.t()]} | {:error, Reason.reason()}) :: pos_integer()
  defp ttl({:ok, _models}), do: Keyword.fetch!(config(), :ttl)
  defp ttl({:error, _reason}), do: Keyword.fetch!(config(), :error_ttl)

  @spec config() :: keyword()
  defp config, do: Application.get_env(:camelot, :model_discovery, [])

  @spec probe_models(probe(), String.t(), String.t()) ::
          {:ok, [String.t()]} | {:error, Reason.reason()}
  defp probe_models(probe, user_id, value) do
    probe.url
    |> ModelApi.impl().list_models(headers(probe.auth, value))
    |> handle_listing(probe, user_id)
  end

  @spec handle_listing({:ok, map()} | {:error, term()}, probe(), String.t()) ::
          {:ok, [String.t()]} | {:error, Reason.reason()}
  defp handle_listing({:ok, body}, probe, _user_id) do
    {:ok, parse_models(body, probe)}
  end

  defp handle_listing({:error, reason}, _probe, user_id) do
    {:error, capture_probe_failed(user_id, reason)}
  end

  @spec headers(String.t(), String.t()) :: ModelApi.headers()
  defp headers("anthropic", "sk-ant-oat" <> _ = value) do
    [
      {"authorization", "Bearer #{value}"},
      {"anthropic-beta", @anthropic_oauth_beta},
      {"anthropic-version", @anthropic_version}
    ]
  end

  defp headers("anthropic", value) do
    [{"x-api-key", value}, {"anthropic-version", @anthropic_version}]
  end

  defp headers("bearer", value), do: [{"authorization", "Bearer #{value}"}]

  # Newest-first, which is how the seeded lists read and how the
  # dropdown is expected to be ordered.
  @spec parse_models(map(), probe()) :: [String.t()]
  defp parse_models(body, probe) do
    body
    |> Map.get(probe.list_key, [])
    |> model_ids(probe.id_key)
    |> included(probe.include)
    |> Enum.sort(:desc)
  end

  @spec model_ids(term(), String.t()) :: [String.t()]
  defp model_ids([], _id_key), do: []

  defp model_ids([_entry | _rest] = entries, id_key) do
    entries
    |> Enum.map(&model_id(&1, id_key))
    |> Enum.filter(&binary_id?/1)
  end

  defp model_ids(_entries, _id_key), do: []

  @spec model_id(term(), String.t()) :: term()
  defp model_id(%{} = entry, id_key), do: Map.get(entry, id_key)
  defp model_id(_entry, _id_key), do: nil

  @spec binary_id?(term()) :: boolean()
  defp binary_id?(id), do: is_binary(id) and id != ""

  @spec included([String.t()], String.t() | nil) :: [String.t()]
  defp included(ids, nil), do: ids

  defp included(ids, pattern) do
    case Regex.compile(pattern) do
      {:ok, regex} -> Enum.filter(ids, &Regex.match?(regex, &1))
      {:error, _reason} -> drop_all(pattern)
    end
  end

  # OpenAI's listing is the whole account catalog (embeddings, tts,
  # whisper, image models), so `include` is load-bearing rather than
  # cosmetic: with a pattern that doesn't compile, offering everything
  # would put `whisper-1` in the Model dropdown. Dropping the lot
  # degrades to the admin's pinned list instead.
  @spec drop_all(String.t()) :: []
  defp drop_all(pattern) do
    Logger.warning("Model discovery include pattern is not a valid regex: #{inspect(pattern)}")

    []
  end

  @spec capture_probe_failed(String.t(), term()) :: Reason.reason()
  defp capture_probe_failed(user_id, reason) do
    {classified, http_status} = Reason.classify(reason)

    Logger.warning("Model discovery failed",
      user_id: user_id,
      reason: classified,
      http_status: http_status
    )

    Capture.capture("agent_models_probe_failed", user_id, %{
      reason: classified,
      http_status: http_status
    })

    classified
  end
end
