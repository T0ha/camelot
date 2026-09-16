#!/usr/bin/env bash
#
# Convert a CapRover-managed swarm service to Global mode.
#
# CapRover cannot create a Global service itself. Its Service Update
# Override is merged additively (Utils.mergeObjects only replaces a key
# when the existing value is falsy), so `Mode: Global: {}` lands *next
# to* the generated `Mode: Replicated`, and docker rejects a spec that
# carries two service modes:
#
#     (HTTP code 400) unexpected - must specify only one service mode
#
# Nor can it be repaired in place - the daemon refuses mode changes:
#
#     rpc error: code = Unimplemented desc = service mode change is not allowed
#
# A service has to be *created* Global. So: let CapRover deploy the app
# normally, then run this once on a swarm manager. It takes the spec
# CapRover generated, swaps only the mode, and recreates the service
# from it, so every label, network, mount and limit is preserved
# verbatim. CapRover keeps managing it afterwards: the override merge is
# a no-op against an already-Global spec, and the replica-count
# assignment is guarded by `if (updatedData.Mode.Replicated)`.
#
# Re-run it if the app is ever deleted and recreated.
#
# Usage: ./bootstrap-global-agent.sh [service-name]    (default: otel-agent)

set -euo pipefail

SERVICE="${1:-otel-agent}"
SOCK=/var/run/docker.sock
API=http://localhost/v1.44

command -v docker >/dev/null || { echo "docker not found - run this on a swarm manager" >&2; exit 1; }
docker node ls >/dev/null 2>&1 || { echo "not a swarm manager" >&2; exit 1; }
docker service inspect "$SERVICE" >/dev/null 2>&1 || { echo "no such service: $SERVICE" >&2; exit 1; }

mode=$(docker service inspect "$SERVICE" --format '{{json .Spec.Mode}}')
case "$mode" in
  *Global*) echo "$SERVICE is already Global - nothing to do."; exit 0 ;;
esac

backup="/tmp/${SERVICE}-spec-$(docker service inspect "$SERVICE" --format '{{.Version.Index}}').json"
docker service inspect "$SERVICE" --format '{{json .Spec}}' > "$backup"
echo "Current spec backed up to $backup"

global="/tmp/${SERVICE}-global.json"
python3 - "$backup" "$global" <<'PY'
import json, sys
spec = json.load(open(sys.argv[1]))
spec["Mode"] = {"Global": {}}
json.dump(spec, open(sys.argv[2], "w"))
PY

# Removing the service briefly stops collection. Offsets live on a host
# mount, so nothing is re-read or lost when it comes back.
echo "Removing $SERVICE ..."
docker service rm "$SERVICE" >/dev/null

echo "Recreating $SERVICE as Global ..."
response=$(curl -s --unix-socket "$SOCK" -X POST \
  -H "Content-Type: application/json" \
  -d @"$global" "$API/services/create")

case "$response" in
  *'"ID"'*) : ;;
  *)
    echo "Create failed: $response" >&2
    echo "Restore with:" >&2
    echo "  curl -s --unix-socket $SOCK -X POST -H 'Content-Type: application/json' -d @$backup $API/services/create" >&2
    exit 1
    ;;
esac

docker service ls --filter "name=$SERVICE" --format '{{.Name}} | {{.Mode}} | {{.Replicas}}'
echo "Done. One task per node should appear shortly:"
docker service ps "$SERVICE" --filter desired-state=running \
  --format '  {{.Node}} | {{.CurrentState}}'
