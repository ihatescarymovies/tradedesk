#!/usr/bin/env bash
# TradeDesk resource-safe build verification gate.
#
# Verifies the COMMITTED tree (HEAD) in a clean disposable copy:
#   1. frozen-lockfile install   pnpm install --frozen-lockfile
#   2. TypeScript check          pnpm exec tsc --noEmit
#   3. production build          pnpm run build
#   4. landing-route smoke       next start on an ephemeral port, GET / must return 200
#
# Resource safety: the disposable working copy and the pnpm CONTENT store live
# under a root-backed directory (default /tmp), so this works even when /home is
# capacity-constrained. The pnpm VIRTUAL store deliberately stays inside the
# project (node_modules/.pnpm): Next 16/Turbopack fails to find the Next.js
# package if the virtual store is moved outside the project root (see PR #2
# verification notes), so only --store-dir may point outside the project.
#
# Uncommitted working-tree changes are NOT tested (the copy is built from
# `git archive HEAD`); use verify:migration, which tests the working tree file.
#
# Environment overrides:
#   VERIFY_TMPDIR   base dir for the disposable working copy (default: $TMPDIR or /tmp)
#   PNPM_STORE_DIR  pnpm content store (default: /tmp/tradedesk-pnpm-store; reused across runs)
#   VERIFY_PORT     port for the landing-route smoke (default: ephemeral free port)
#   KEEP_WORK=1     keep the working copy and server log on failure for inspection
set -euo pipefail

command -v git  >/dev/null 2>&1 || { echo "verify: FAIL — git is required" >&2; exit 1; }
command -v pnpm >/dev/null 2>&1 || { echo "verify: FAIL — pnpm is required (corepack enable or install pnpm)" >&2; exit 1; }
command -v node >/dev/null 2>&1 || { echo "verify: FAIL — node is required" >&2; exit 1; }

REPO_ROOT=$(git rev-parse --show-toplevel)
VERIFY_TMPDIR="${VERIFY_TMPDIR:-${TMPDIR:-/tmp}}"
PNPM_STORE_DIR="${PNPM_STORE_DIR:-/tmp/tradedesk-pnpm-store}"
KEEP_WORK="${KEEP_WORK:-0}"
SERVER_PID=""
WORK_DIR=""

cleanup() {
  if [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" 2>/dev/null; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  if [ -n "$WORK_DIR" ] && [ -d "$WORK_DIR" ]; then
    if [ "$KEEP_WORK" = "1" ]; then
      echo "verify: KEEP_WORK=1 — disposable working copy left at $WORK_DIR"
    else
      rm -rf "$WORK_DIR"
    fi
  fi
}
trap cleanup EXIT

fail() { echo "verify: FAIL — $1" >&2; exit 1; }

# http_code <url> — prints the HTTP status, or 000 if unreachable.
http_code() {
  if command -v curl >/dev/null 2>&1; then
    curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$1" || echo 000
  else
    node -e 'fetch(process.argv[1]).then(r=>{console.log(r.status)}).catch(()=>console.log("000"))' "$1"
  fi
}

[ -d "$VERIFY_TMPDIR" ] || mkdir -p "$VERIFY_TMPDIR"
[ -d "$PNPM_STORE_DIR" ] || mkdir -p "$PNPM_STORE_DIR"

PORT="${VERIFY_PORT:-}"
if [ -z "$PORT" ]; then
  PORT=$(python3 - 2>/dev/null <<'PY' || echo 3217
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
)
fi
[ -n "$PORT" ] || PORT=3217

HEAD_SHA=$(git rev-parse --short HEAD)
echo "verify: repo                  : $REPO_ROOT"
echo "verify: verifying committed   : HEAD=$HEAD_SHA (git archive; uncommitted changes not tested)"
echo "verify: working copy base     : $VERIFY_TMPDIR"
echo "verify: pnpm content store    : $PNPM_STORE_DIR"
echo "verify: smoke port            : $PORT"

WORK_DIR=$(mktemp -d "$VERIFY_TMPDIR/tradedesk-verify.XXXXXX")
echo "verify: disposable working copy: $WORK_DIR"

git archive --format=tar HEAD | tar -x -C "$WORK_DIR"
cd "$WORK_DIR"

echo "==> [1/4] pnpm install --frozen-lockfile --store-dir $PNPM_STORE_DIR"
pnpm install --frozen-lockfile --store-dir "$PNPM_STORE_DIR"

echo "==> [2/4] pnpm exec tsc --noEmit"
pnpm exec tsc --noEmit

echo "==> [3/4] pnpm run build"
NEXT_TELEMETRY_DISABLED=1 pnpm run build

echo "==> [4/4] landing-route smoke: next start on :$PORT, GET / must return 200"
NEXT_TELEMETRY_DISABLED=1 pnpm exec next start -p "$PORT" >"$WORK_DIR/server.log" 2>&1 &
SERVER_PID=$!

READY=0
for _ in $(seq 1 60); do
  if [ "$(http_code "http://127.0.0.1:$PORT/")" = "200" ]; then READY=1; break; fi
  sleep 2
done
if [ "$READY" != "1" ]; then
  echo "verify: server log (tail):" >&2
  tail -20 "$WORK_DIR/server.log" >&2 || true
  fail "landing route did not return 200 within 120s (log: $WORK_DIR/server.log; re-run with KEEP_WORK=1 to keep it)"
fi
CODE=$(http_code "http://127.0.0.1:$PORT/")
[ "$CODE" = "200" ] || fail "landing route returned HTTP $CODE (expected 200)"

echo "verify: landing route OK (HTTP $CODE on /)"
echo "verify: ALL BUILD CHECKS PASSED (install / tsc --noEmit / build / landing-route smoke)"
