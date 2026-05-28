[
  # Third-party warning in ash_oban's transformer — cannot be fixed downstream.
  # Ash.ActionInput contains opaque subterms that dialyzer flags on set_tenant/2.
  {"deps/ash_oban/lib/transformers/define_action_workers.ex", :call_without_opaque}
]
