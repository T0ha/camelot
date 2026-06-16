[
  # Third-party warning in ash_oban's transformer — cannot be fixed downstream.
  # Ash.ActionInput contains opaque subterms that dialyzer flags on set_tenant/2.
  {"deps/ash_oban/lib/transformers/define_action_workers.ex", :call_without_opaque},
  # Mix isn't in the release runtime, so it's also not in dialyzer's PLT —
  # `use Mix.Task` flags `callback_info_missing`. Harmless: the task only
  # runs under `mix camelot.create_user` (or `bin/camelot eval`) in contexts
  # where Mix is actually loaded.
  {"lib/mix/tasks/camelot.create_user.ex", :callback_info_missing}
]
