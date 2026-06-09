#!/usr/bin/env bash
# Per-session `docker exec` invocations land here. The container's
# entrypoint already ran materialise_secrets / merge_mcp_config /
# clone / asdf install, and persisted the resolved env to
# /tmp/camelot.env. We source it so the exec'd command sees the same
# credentials and tooling the entrypoint set up.
set -euo pipefail

if [ -f /tmp/camelot.env ]; then
  # shellcheck disable=SC1091
  . /tmp/camelot.env
fi

# Ensure asdf shims are on PATH so `claude`, `codex`, etc. resolve
# the same way they would inside an interactive shell.
if [ -f "$HOME/.asdf/asdf.sh" ]; then
  # shellcheck disable=SC1091
  . "$HOME/.asdf/asdf.sh"
fi

cd /workspace 2>/dev/null || true

exec "$@"
