#!/usr/bin/env bash
# Per-session `docker exec` invocations land here. The container's
# entrypoint already persisted resolved env to /tmp/camelot.env at
# boot, but those values can go stale (e.g. credential rotated via
# the UI after the container started). Each exec from the BEAM also
# passes the current `Env` over the Docker API, so we treat
# /tmp/camelot.env as a fallback only — variables already set by
# `docker exec` win.
set -euo pipefail

if [ -f /tmp/camelot.env ]; then
  while IFS= read -r line; do
    case "$line" in
      export\ *=*) ;;
      *) continue ;;
    esac

    var="${line#export }"
    name="${var%%=*}"
    # Only set if not already provided by the exec-time environment.
    if [ -z "${!name+x}" ]; then
      export "$var"
    fi
  done < /tmp/camelot.env
fi

# Ensure asdf shims are on PATH so `claude`, `codex`, etc. resolve
# the same way they would inside an interactive shell.
if [ -f "${ASDF_DIR:-/opt/asdf}/asdf.sh" ]; then
  # shellcheck disable=SC1091
  . "${ASDF_DIR:-/opt/asdf}/asdf.sh"
fi

cd /workspace 2>/dev/null || true

# Task sessions arrive as `docker exec` with the credentials in the
# exec-time environment, which the container's entrypoint never saw —
# so authenticate Codex here too. It reads $CODEX_HOME/auth.json and
# never OPENAI_API_KEY, so an env-only key means every request goes out
# unauthenticated ("Missing bearer or basic authentication in header").
# Idempotent, and a no-op in images without the CLI.
if [ -n "${OPENAI_API_KEY:-}" ] && command -v codex >/dev/null 2>&1; then
  printf '%s' "$OPENAI_API_KEY" | codex login --with-api-key >/dev/null 2>&1 \
    || echo "[exec-wrapper] codex login failed; Codex runs will 401" >&2
fi

# A CLI that takes its structured-output schema as a file (Codex's
# `--output-schema`) is handed the path in its argv, built by the BEAM
# before it knew which backend would run it. Materialise the schema at
# that same path. Session-scoped so concurrent sessions can't race.
if [ -n "${CAMELOT_OUTPUT_SCHEMA_JSON:-}" ]; then
  printf '%s' "$CAMELOT_OUTPUT_SCHEMA_JSON" \
    > "/tmp/camelot-output-schema-${CAMELOT_SESSION_ID:-session}.json"
fi

# Tee the agent's output to a per-session file so the BEAM can fetch
# the complete result with a short `docker exec cat` after the process
# exits, instead of depending on the long-lived, mostly-idle exec
# stream (which an intermediary can sever on long runs, losing the
# single final JSON blob). stdout still flows to the exec stream for
# live output. `set -e` must not abort before we read PIPESTATUS.
out="/tmp/camelot-output-${CAMELOT_SESSION_ID:-session}.log"
set +e
"$@" 2>&1 | tee "$out"
code=${PIPESTATUS[0]}
set -e

# Completion marker: the exit code in its own file. After a Camelot
# restart the original `docker exec` id is lost, so the BEAM can't poll
# the exec for its exit status. An adopting session instead polls for
# this marker to learn the run finished (and with what code), then reads
# the tee'd output file above. Written last so its presence strictly
# implies the output file is complete.
echo "$code" > "/tmp/camelot-exit-${CAMELOT_SESSION_ID:-session}"
exit "$code"
