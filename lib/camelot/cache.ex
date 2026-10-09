defmodule Camelot.Cache do
  @moduledoc """
  Shared in-memory cache for the whole application.

  A general-purpose Nebulex cache rather than a per-feature one: every
  caller namespaces its own keys (`{:model_discovery, user_id, digest}`
  for `Camelot.Agents.ModelDiscovery`), so one supervised ETS-backed
  store covers all of them.

  Local to the node — the local adapter keeps entries in ETS, so two
  web nodes warm their own copies. That is deliberate: everything
  cached here is derived data a miss can recompute, and the
  alternative (a distributed adapter) buys consistency nothing here
  needs.

  Entries are expected to carry a per-entry `ttl:`; the generational
  garbage collector configured in `config/config.exs` may also drop an
  entry *early* under memory pressure, never late. Both outcomes are a
  miss, and a miss is always safe.

  Callers must treat a cache *error* as a miss too: a fault in here
  should degrade a page to a recomputed value, never break it.
  """
  use Nebulex.Cache,
    otp_app: :camelot,
    adapter: Nebulex.Adapters.Local
end
