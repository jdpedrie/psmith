#!/bin/bash
# End-to-end Mac tests: a real psmithd on a fresh database and the demo
# seeder's fake model, then the Mac test target's E2E suites (which skip
# without them), each in an offscreen window.
#
#   scripts/mac-e2e.sh [swift test --filter pattern]
#
# With no pattern it runs every suite under Tests/PsmithMacSnapshotTests/E2E,
# one at a time: windows from suites running side by side take key focus
# from each other mid-typing.
# Two runs can go at once: give each its own PSMITH_E2E_PORT,
# PSMITH_E2E_LLM_PORT and PSMITH_E2E_SCRATCH (a build directory).
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
PGHOST=${PGTESTDB_HOST:-localhost}; PGPORT=${PGTESTDB_PORT:-5433}
PGUSER=${PGTESTDB_USER:-clark}; PGPASS=${PGTESTDB_PASSWORD:-clark}
DB="psmith_mac_e2e_$(date +%s)"
DSN="postgres://$PGUSER:$PGPASS@$PGHOST:$PGPORT/$DB?sslmode=disable"
PORT=${PSMITH_E2E_PORT:-18092}
LLM_PORT=${PSMITH_E2E_LLM_PORT:-19098}
FILTER=${1:-E2ETests}
ADMIN_PASSWORD=admin-password-not-secret

cleanup() {
	[ -n "${PID:-}" ] && kill "$PID" 2>/dev/null || true
	[ -n "${LLM_PID:-}" ] && kill "$LLM_PID" 2>/dev/null || true
	docker exec clark-postgres psql -U "$PGUSER" -d "${PGTESTDB_DB:-clark}" -qc "DROP DATABASE IF EXISTS \"$DB\" WITH (FORCE)" >/dev/null 2>&1 || true
}
trap cleanup EXIT

docker exec clark-postgres psql -U "$PGUSER" -d "${PGTESTDB_DB:-clark}" -qc "CREATE DATABASE \"$DB\""
goose -dir db/migrations postgres "$DSN" up >/dev/null
BIN="bin/mac-e2e-$PORT"
mkdir -p "$BIN"
go build -o "$BIN/psmithd" ./cmd/psmithd
# The demo seeder's fake OpenAI-compatible model, streaming word by word with
# a delay, so tests can watch a reply arrive.
go build -o "$BIN/demo-seed" ./cmd/demo-seed
"$BIN/demo-seed" -llm-only -llm-port "$LLM_PORT" -chunk-delay "${PSMITH_E2E_CHUNK_DELAY:-80ms}" \
	-slow-start "${PSMITH_E2E_SLOW_START:-4s}" >"${TMPDIR:-/tmp}/psmith-mac-e2e-llm-$LLM_PORT.log" 2>&1 &
LLM_PID=$!
PSMITH_DSN="$DSN" PSMITH_ADDR="127.0.0.1:$PORT" PSMITH_BOOTSTRAP_ADMIN_USERNAME=admin \
	PSMITH_BOOTSTRAP_ADMIN_PASSWORD="$ADMIN_PASSWORD" PSMITH_CATALOG_REFRESH_INTERVAL=0 \
	"$BIN/psmithd" >"${TMPDIR:-/tmp}/psmith-mac-e2e-$PORT.log" 2>&1 &
PID=$!
for _ in $(seq 1 100); do nc -z 127.0.0.1 "$PORT" 2>/dev/null && break; sleep 0.1; done
nc -z 127.0.0.1 "$PORT" || { echo "psmithd did not start"; cat "${TMPDIR:-/tmp}/psmith-mac-e2e-$PORT.log"; exit 1; }

OUT="${PSMITH_E2E_OUT:-${TMPDIR:-/tmp}/psmith-mac-e2e}"
rm -rf "$OUT/mac-e2e"
cd clients/psmithd-mac
PSMITH_E2E_URL="http://127.0.0.1:$PORT" PSMITH_E2E_USER=admin PSMITH_E2E_PASSWORD="$ADMIN_PASSWORD" \
PSMITH_E2E_LLM="http://127.0.0.1:$LLM_PORT/v1" PSMITH_SNAP_OUT="$OUT" \
	swift test ${PSMITH_E2E_SCRATCH:+--scratch-path "$PSMITH_E2E_SCRATCH"} --no-parallel --filter "$FILTER"
