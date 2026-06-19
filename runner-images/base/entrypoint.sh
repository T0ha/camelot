#!/usr/bin/env bash
# Camelot runner entrypoint.
#
# Idempotent boot:
#   1. Materialise /run/secrets/<kind> into the right dotfile.
#   2. Merge image-baked MCPs with PROJECT_MCP_CONFIG_JSON.
#   3. If BOOTSTRAP=1, run the command and exit (no clone).
#   4. Else, clone REPO_URL into /workspace, asdf install, exec command.
#
# The cache volume at /home/agent is treated as disposable — every step
# below works fine on an empty volume.

set -euo pipefail

log() { printf '[entrypoint] %s\n' "$*" >&2; }

# Per-task containers boot once with this entrypoint, then sleep.
# Per-session `docker exec` invocations bypass entrypoint.sh and
# inherit only the container's create-time env — so they don't see
# anything `materialise_secrets` exports here. We mirror each export
# to /tmp/camelot.env (sourced by /exec-wrapper.sh) so subsequent
# execs get the same credentials.
CAMELOT_ENV_FILE="/tmp/camelot.env"
CAMELOT_READY_FILE="/tmp/camelot-ready"

persist_env() {
  printf 'export %s=%q\n' "$1" "$2" >> "$CAMELOT_ENV_FILE"
}

materialise_secrets() {
  # Source 1: Swarm secrets at /run/secrets/<kind> — used in the
  # Swarm backend. Source 2: env vars (canonical for known CLI tools
  # plus CAMELOT_SECRET_<KIND> for anything else) — used in the
  # DockerEngine / LocalPort backends. Both paths are idempotent.

  local secrets_dir=/run/secrets
  if [ -d "$secrets_dir" ]; then
    local f kind
    for f in "$secrets_dir"/*; do
      [ -f "$f" ] || continue
      kind="$(basename "$f")"
      materialise_one "$kind" "$(cat "$f")"
    done
  fi

  # Canonical env vars set by the DockerEngine runner.
  [ -n "${ANTHROPIC_API_KEY:-}" ] && materialise_one claude_api_key "$ANTHROPIC_API_KEY"
  [ -n "${OPENAI_API_KEY:-}"    ] && materialise_one openai_api_key  "$OPENAI_API_KEY"
  [ -n "${GH_TOKEN:-}"          ] && materialise_one github_pat      "$GH_TOKEN"

  # Generic CAMELOT_SECRET_* env var fallback for kinds without a
  # natural canonical env var (claude_oauth, ssh_private_key, generic).
  #
  # Iterate variable NAMES via compgen and look up values with bash
  # indirect expansion — `env | while read` would split multi-line
  # values (e.g. OpenSSH private keys) at the first newline.
  local var kind
  while IFS= read -r var; do
    case "$var" in
      CAMELOT_SECRET_*)
        kind="$(printf '%s' "${var#CAMELOT_SECRET_}" | tr '[:upper:]' '[:lower:]')"
        materialise_one "$kind" "${!var}"
        ;;
    esac
  done < <(compgen -e)
}

materialise_one() {
  local kind="$1"
  local value="$2"
  case "$kind" in
    claude_api_key)
      case "$value" in
        sk-ant-oat*)
          unset ANTHROPIC_API_KEY
          export CLAUDE_CODE_OAUTH_TOKEN="$value"
          persist_env CLAUDE_CODE_OAUTH_TOKEN "$value"
          ;;
        *)
          export ANTHROPIC_API_KEY="$value"
          persist_env ANTHROPIC_API_KEY "$value"
          ;;
      esac
      ;;
    openai_api_key|codex_api_key)
      export OPENAI_API_KEY="$value"
      persist_env OPENAI_API_KEY "$value"
      ;;
    github_pat|github_oauth)
      export GH_TOKEN="$value"
      export GITHUB_TOKEN="$value"
      persist_env GH_TOKEN "$value"
      persist_env GITHUB_TOKEN "$value"
      ;;
    ssh_private_key)
      mkdir -p "$HOME/.ssh"
      printf '%s' "$value" > "$HOME/.ssh/id_ed25519"
      chmod 600 "$HOME/.ssh/id_ed25519"
      ssh-keyscan -t ed25519 github.com >> "$HOME/.ssh/known_hosts" 2>/dev/null || true
      ;;
    generic)
      :
      ;;
    *)
      log "unknown secret kind: $kind"
      ;;
  esac
}

merge_mcp_config() {
  local defaults=/etc/camelot/mcp.defaults.json
  local out="$HOME/.config/camelot/mcp.json"

  mkdir -p "$(dirname "$out")"

  if [ -n "${PROJECT_MCP_CONFIG_JSON:-}" ]; then
    # Resolve ${credential:<kind>} placeholders. Each placeholder is
    # replaced with the value of /run/secrets/<kind> if present.
    local resolved
    resolved="$(printf '%s' "$PROJECT_MCP_CONFIG_JSON" | \
      awk '
        function read_file(p,   line, out) {
          out = ""
          while ((getline line < p) > 0) out = out line
          close(p)
          return out
        }
        {
          line = $0
          while (match(line, /\${credential:[a-z_]+}/)) {
            placeholder = substr(line, RSTART, RLENGTH)
            kind = substr(placeholder, 14, RLENGTH - 14)
            secret = read_file("/run/secrets/" kind)
            line = substr(line, 1, RSTART - 1) secret substr(line, RSTART + RLENGTH)
          }
          print line
        }')"
    printf '%s' "$resolved" > "$out"
  else
    cp "$defaults" "$out"
  fi
}

clone_workspace() {
  local url="${REPO_URL:-}"
  local branch="${REPO_BRANCH:-}"

  [ -n "$url" ] || { log "no REPO_URL set; skipping clone"; return 0; }

  log "cloning $url into /workspace"
  cd /workspace
  if [ -n "$branch" ]; then
    git clone --depth 50 --branch "$branch" "$url" .
  else
    git clone --depth 50 "$url" .
  fi
}

install_repo_languages() {
  cd /workspace
  if [ -f .tool-versions ]; then
    log "asdf install (from .tool-versions)"
    # Best-effort — don't fail the run if a plugin is missing.
    asdf install || log "asdf install reported errors; continuing"
  fi
}

mark_ready() {
  touch "$CAMELOT_READY_FILE"
}

# Seed $HOME files that would otherwise be hidden by the per-task profile
# volume mounted at /home/agent. The image bakes immutable defaults under
# /opt; this seeds the mutable per-user view on first boot.
seed_home() {
  if [ ! -f "$HOME/.tool-versions" ] && [ -f /opt/asdf/default-tool-versions ]; then
    cp /opt/asdf/default-tool-versions "$HOME/.tool-versions"
  fi
}

main() {
  source "${ASDF_DIR:-/opt/asdf}/asdf.sh" 2>/dev/null || true
  seed_home

  # Truncate any stale env from a previous container lifecycle (only
  # relevant if /tmp is somehow persisted; defensive).
  : > "$CAMELOT_ENV_FILE"

  materialise_secrets
  merge_mcp_config

  if [ "${BOOTSTRAP:-0}" = "1" ]; then
    log "bootstrap mode; running command without clone"
    mark_ready
    exec "$@"
  fi

  clone_workspace
  install_repo_languages
  mark_ready

  log "exec: $*"
  exec "$@"
}

main "$@"
