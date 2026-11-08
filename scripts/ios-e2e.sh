#!/bin/bash
# End-to-end iOS tests: a real psmithd on a fresh database, and the iOS test
# target's E2E tests (which skip without it) run against it in the simulator.
# The simulator reaches the Mac's localhost directly.
#
#   scripts/ios-e2e.sh [xcodebuild -only-testing filter]
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
PGHOST=${PGTESTDB_HOST:-localhost}; PGPORT=${PGTESTDB_PORT:-5433}
PGUSER=${PGTESTDB_USER:-clark}; PGPASS=${PGTESTDB_PASSWORD:-clark}
DB="psmith_ios_e2e_$(date +%s)"
DSN="postgres://$PGUSER:$PGPASS@$PGHOST:$PGPORT/$DB?sslmode=disable"
PORT=${PSMITH_E2E_PORT:-18091}
FILTER=${1:-PsmithiOSSnapshotTests/NewConversationE2ETests}
SIM=${IOS_SIMULATOR:-iPhone 17 Pro}
ADMIN_PASSWORD=admin-password-not-secret

LLM_PORT=${PSMITH_E2E_LLM_PORT:-19099}

cleanup() {
	[ -n "${PID:-}" ] && kill "$PID" 2>/dev/null || true
	[ -n "${LLM_PID:-}" ] && kill "$LLM_PID" 2>/dev/null || true
	docker exec clark-postgres psql -U "$PGUSER" -d "${PGTESTDB_DB:-clark}" -qc "DROP DATABASE IF EXISTS \"$DB\" WITH (FORCE)" >/dev/null 2>&1 || true
}
trap cleanup EXIT

docker exec clark-postgres psql -U "$PGUSER" -d "${PGTESTDB_DB:-clark}" -qc "CREATE DATABASE \"$DB\""
goose -dir db/migrations postgres "$DSN" up >/dev/null
go build -o bin/psmithd-test ./cmd/psmithd
# The demo seeder's fake OpenAI-compatible model, streaming word by word with
# a delay, so tests can watch a reply arrive.
go build -o bin/demo-seed-test ./cmd/demo-seed
bin/demo-seed-test -llm-only -llm-port "$LLM_PORT" -chunk-delay "${PSMITH_E2E_CHUNK_DELAY:-80ms}" >"${TMPDIR:-/tmp}/psmith-ios-e2e-llm.log" 2>&1 &
LLM_PID=$!
PSMITH_DSN="$DSN" PSMITH_ADDR="127.0.0.1:$PORT" PSMITH_BOOTSTRAP_ADMIN_USERNAME=admin \
	PSMITH_BOOTSTRAP_ADMIN_PASSWORD="$ADMIN_PASSWORD" PSMITH_CATALOG_REFRESH_INTERVAL=0 \
	bin/psmithd-test >"${TMPDIR:-/tmp}/psmith-ios-e2e.log" 2>&1 &
PID=$!
for _ in $(seq 1 100); do nc -z 127.0.0.1 "$PORT" 2>/dev/null && break; sleep 0.1; done
nc -z 127.0.0.1 "$PORT" || { echo "psmithd did not start"; cat "${TMPDIR:-/tmp}/psmith-ios-e2e.log"; exit 1; }

# A test app left over from the previous run makes the simulator refuse the
# next launch ("Busy"), and old timelines could pass for this run's.
# Boot the device xcodebuild will pick (the newest runtime's "$SIM") and wait
# for it to finish: launching into a half-booted simulator fails as "Busy".
UDID=$(xcrun simctl list devices available -j | python3 -c '
import json, sys
name = sys.argv[1]
devs = json.load(sys.stdin)["devices"]
best = None
for rt, ds in devs.items():
    if "iOS" not in rt:
        continue
    for d in ds:
        if d["name"] == name and (best is None or rt > best[0]):
            best = (rt, d["udid"])
print(best[1] if best else "")' "$SIM")
xcrun simctl terminate "$UDID" dev.jdpedrie.PsmithiOS >/dev/null 2>&1 || true
xcrun simctl boot "$UDID" >/dev/null 2>&1 || true
xcrun simctl bootstatus "$UDID" -b >/dev/null
OUT="${PSMITH_E2E_OUT:-${TMPDIR:-/tmp}/psmith-ios-e2e}"
rm -rf "$OUT/e2e"

TEST_RUNNER_PSMITH_E2E_URL="http://127.0.0.1:$PORT" TEST_RUNNER_PSMITH_E2E_USER=admin \
TEST_RUNNER_PSMITH_E2E_PASSWORD="$ADMIN_PASSWORD" \
TEST_RUNNER_PSMITH_E2E_LLM="http://127.0.0.1:$LLM_PORT/v1" \
TEST_RUNNER_PSMITH_SNAP_OUT="$OUT" \
xcodebuild test \
	-project clients/psmithd-ios/PsmithiOS.xcodeproj -scheme PsmithiOS \
	-destination "platform=iOS Simulator,id=$UDID" \
	-derivedDataPath clients/psmithd-ios/.build \
	-only-testing:"$FILTER"
