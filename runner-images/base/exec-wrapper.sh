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

exec "$@"
