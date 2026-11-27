#!/usr/bin/env bash
# Downloads the card's attachments into the workspace.
#
# ATTACHMENTS_JSON is a JSON array of {"filename": ..., "url": ...}
# built by the BEAM (`TaskRunner.build_spec/4`) with freshly signed
# download links. Run at container boot by entrypoint.sh and again
# before every session by exec-wrapper.sh: a task keeps one long-lived
# container, so files uploaded after it booted only arrive through the
# exec-time ATTACHMENTS_JSON.
#
# Behaviour:
#   * Files land in $CAMELOT_ATTACHMENTS_DIR
#     (default /workspace/.camelot/attachments).
#   * A file that already exists with a non-zero size is skipped.
#   * Downloads go to a temp file in the same dir, then `mv` into
#     place, so the agent never sees a half-written file.
#   * Files in the dir that are no longer listed (deleted in the UI)
#     are removed. Only regular files directly in the dir are touched.
#   * `.camelot/attachments/` is added to .git/info/exclude so an
#     agent's `git add -A` can't commit the user's private files.
#   * Never fails the caller: every error is logged and the script
#     always exits 0.
#
# Requires curl and jq.

set -uo pipefail

DIR="${CAMELOT_ATTACHMENTS_DIR:-/workspace/.camelot/attachments}"
WORKSPACE="${CAMELOT_WORKSPACE_DIR:-/workspace}"
EXCLUDE_LINE=".camelot/attachments/"

# stderr goes to the session's output stream. When the exec-wrapper
# sets CAMELOT_ATTACHMENTS_LOG (to PID 1's stderr), mirror there too so
# the line also shows up in the container's own log.
log() {
  printf '[camelot] %s\n' "$*" >&2
  local mirror="${CAMELOT_ATTACHMENTS_LOG:-}"
  if [ -n "$mirror" ] && [ -w "$mirror" ]; then
    printf '[camelot] %s\n' "$*" >> "$mirror" 2>/dev/null || true
  fi
}

# Basename only; rejects empty, `.`, `..` and names with a newline.
# Prints the safe name, or nothing.
safe_name() {
  local name="${1##*/}"
  case "$name" in
    "" | "." | "..") return 0 ;;
    *$'\n'*) return 0 ;;
  esac
  printf '%s' "$name"
}

exclude_from_git() {
  [ -d "$WORKSPACE/.git" ] || return 0

  local exclude="$WORKSPACE/.git/info/exclude"
  mkdir -p "$WORKSPACE/.git/info" || return 0
  grep -qxF "$EXCLUDE_LINE" "$exclude" 2>/dev/null && return 0
  printf '%s\n' "$EXCLUDE_LINE" >> "$exclude" || true
}

# fetch_one <name> <url>
fetch_one() {
  local name="$1" url="$2" target="$DIR/$1" tmp

  [ -s "$target" ] && return 0

  if ! tmp="$(mktemp "$DIR/.fetch.XXXXXX")"; then
    log "failed to fetch attachment $name"
    return 0
  fi

  if curl -fsSL --retry 2 --max-time 120 "$url" -o "$tmp" \
    && mv -f "$tmp" "$target"; then
    log "fetched attachment $name"
  else
    rm -f "$tmp"
    log "failed to fetch attachment $name"
  fi
}

# Removes regular files in $DIR whose names aren't in the listing.
prune() {
  local -n wanted_ref="$1"
  local path name

  for path in "$DIR"/* "$DIR"/.[!.]* "$DIR"/..?*; do
    [ -f "$path" ] || continue
    name="${path##*/}"
    [ -n "${wanted_ref[$name]+x}" ] && continue
    rm -f "$path" && log "removed attachment $name"
  done
}

main() {
  [ -n "${ATTACHMENTS_JSON:-}" ] || return 0

  local entries
  if ! entries="$(printf '%s' "$ATTACHMENTS_JSON" | jq -c '.[]' 2>/dev/null)"
  then
    log "ATTACHMENTS_JSON is not a JSON array; skipping attachments"
    return 0
  fi

  mkdir -p "$DIR" || {
    log "cannot create $DIR; skipping attachments"
    return 0
  }

  exclude_from_git

  local -A wanted=()
  local entry raw url name

  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    raw="$(jq -r '.filename // empty' <<< "$entry")"
    url="$(jq -r '.url // empty' <<< "$entry")"
    name="$(safe_name "$raw")"

    if [ -z "$name" ] || [ -z "$url" ]; then
      log "skipping attachment with an invalid name or url: $raw"
      continue
    fi

    wanted[$name]=1
    fetch_one "$name" "$url"
  done <<< "$entries"

  prune wanted
}

main
exit 0
