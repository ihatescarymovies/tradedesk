#!/usr/bin/env bash
# TradeDesk migration-contract regression gate (disposable local PostgreSQL).
#
# Runs the working-tree db/migration.sql against throwaway databases and asserts
# the reminder-template canonicalization contract:
#   1. FRESH INSTALL       completes under a non-default search_path (custom,public)
#                          and creates public.reminder_templates.
#   2. STRICT-PATH LEGACY  upgrade with data in public.reminder_template COMPLETES
#                          under search_path=custom (public absent) — the contract
#                          restored by PR #2 (f0a7b42: qualify reminders.template_id
#                          FK as public.reminder_templates). Legacy rows and FKs are
#                          preserved and the reminders FK targets public.reminder_templates.
#   3. CANONICAL RE-RUN    a second pass is idempotent (rc=0, no duplicated rows).
#   4. DUAL-TABLE STOP     when both reminder_template and reminder_templates exist,
#                          the migration aborts with the explicit "both ... exist"
#                          safety exception and strands no data.
#
# OUT OF SCOPE (not claimed fixed by this gate): the reminder-cron handler
# (src/app/api/cron/send-reminders/route.ts) inserts into reminders without the
# NOT NULL user_id column. That is a separate runtime defect tracked elsewhere.
#
# Prerequisites (documented; the script FAILS with instructions if unavailable,
# it never installs anything):
#   - PostgreSQL client tools and a reachable server, run as the postgres
#     superuser via passwordless sudo (`sudo -u postgres`). Install on Ubuntu:
#       sudo apt-get update && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y postgresql postgresql-client
#       sudo pg_ctlcluster 16 main start
#     (check status: pg_lsclusters / pg_isready)
#   - The script attempts `pg_ctlcluster ... start` once if a cluster is
#     installed but down; it does not create clusters.
#
# Gotchas handled internally: PGOPTIONS is stripped by sudo's env_reset, so the
# custom search_path is passed as `sudo -u postgres env PGOPTIONS=... psql`;
# assertions use fully-qualified names so they are immune to search_path.
#
# Environment overrides:
#   MIGRATION_FILE  migration to test (default: <repo>/db/migration.sql, working tree)
#   WORK_DIR        BASE directory for scratch logs (default: ${TMPDIR:-/tmp}/tradedesk-migration-regression);
#                   a unique child scratch dir is created under it per run, and only that child is removed
#   KEEP_WORK=1     keep scratch logs and the disposable databases on exit for inspection
#
# Safety: this script never drops a database it did not create. Database names are
# generated per run (timestamp+pid+random); if a name already exists, `createdb`
# fails and the run aborts — nothing is dropped first. Cleanup drops only the
# databases this invocation created and removes only its own scratch child dir.
set -u

# --- locate repo + migration -------------------------------------------------
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || dirname "$SCRIPT_DIR")
MIGRATION_FILE="${MIGRATION_FILE:-$REPO_ROOT/db/migration.sql}"
[ -f "$MIGRATION_FILE" ] || { echo "regress: FAIL — migration not found at $MIGRATION_FILE (set MIGRATION_FILE)" >&2; exit 1; }

WORK_BASE="${WORK_DIR:-${TMPDIR:-/tmp}/tradedesk-migration-regression}"
KEEP_WORK="${KEEP_WORK:-0}"
DB_PREFIX="tdreg_$(date +%s)_$$_$RANDOM"   # unique per run so concurrent runs do not clash
FAILURES=0
DB_NAMES=""

note() { printf '\n=== %s ===\n' "$1"; }
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; FAILURES=$((FAILURES + 1)); }

# --- preflight ----------------------------------------------------------------
MISSING=""
for t in psql createdb dropdb; do
  command -v "$t" >/dev/null 2>&1 || MISSING="$MISSING $t"
done
if [ -n "$MISSING" ]; then
  cat >&2 <<EOF
regress: FAIL — missing PostgreSQL client tool(s):$MISSING
  Install PostgreSQL (client + server), e.g. on Ubuntu:
    sudo apt-get update && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y postgresql postgresql-client
  Then start the cluster: sudo pg_ctlcluster 16 main start
  The script needs passwordless sudo to run psql as the postgres superuser.
EOF
  exit 1
fi
command -v sudo >/dev/null 2>&1 || { echo "regress: FAIL — sudo is required to run psql as the postgres superuser" >&2; exit 1; }

if ! sudo -u postgres psql -X -qAt -c 'SELECT 1' >/dev/null 2>&1; then
  if command -v pg_ctlcluster >/dev/null 2>&1 && command -v pg_lsclusters >/dev/null 2>&1; then
    CLUSTER=$(pg_lsclusters 2>/dev/null | awk 'NR>1 && $4=="down"{print $1" "$2; exit}')
    if [ -n "$CLUSTER" ]; then
      echo "regress: PostgreSQL cluster ($CLUSTER) is installed but down — attempting start"
      sudo pg_ctlcluster $CLUSTER start
    fi
  fi
  if ! sudo -u postgres psql -X -qAt -c 'SELECT 1' >/dev/null 2>&1; then
    cat >&2 <<EOF
regress: FAIL — no reachable PostgreSQL server for the postgres superuser.
  Start the cluster: sudo pg_ctlcluster 16 main start   (check: pg_isready)
  If PostgreSQL is not installed:
    sudo apt-get update && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y postgresql postgresql-client
    sudo pg_ctlcluster 16 main start
EOF
    exit 1
  fi
fi

mkdir -p "$WORK_BASE" || { echo "regress: FAIL — cannot create scratch base $WORK_BASE" >&2; exit 1; }
WORK_DIR=$(mktemp -d "$WORK_BASE/tdreg.XXXXXX") || { echo "regress: FAIL — cannot create scratch dir under $WORK_BASE" >&2; exit 1; }
echo "regress: scratch dir: $WORK_DIR"

# --- helpers -------------------------------------------------------------------
# run the migration as postgres under a custom search_path; echoes the exit code
run_migration() { # $1=db  $2=search_path  $3=outfile
  sudo -u postgres env PGOPTIONS="-c search_path=$2" psql -X -v ON_ERROR_STOP=1 -d "$1" -f "$MIGRATION_FILE" >"$3" 2>&1
  echo $?
}
# assert query as postgres with default search_path (fully-qualified SQL only)
q() { sudo -u postgres psql -X -qAt -d "$1" -c "$2" 2>/dev/null; }
mkdb() { # $1=db — createdb must succeed; a name that already exists aborts safely (never dropped)
  if ! DBERR=$(sudo -u postgres createdb "$1" 2>&1); then
    fail "could not create database $1 — name may already exist, refusing to drop it (createdb: $DBERR)"
    return 1
  fi
  DB_NAMES="$DB_NAMES $1"
}
cleanup() {
  for db in $DB_NAMES; do
    sudo -u postgres dropdb --if-exists "$db" >/dev/null 2>&1
  done
  if [ "$KEEP_WORK" = "1" ]; then
    echo "regress: KEEP_WORK=1 — scratch logs kept in $WORK_DIR (databases were still dropped)"
  else
    rm -rf "$WORK_DIR"
  fi
}
trap cleanup EXIT

LEGACY_PRESQL="CREATE SCHEMA IF NOT EXISTS custom;
CREATE TABLE IF NOT EXISTS public.users (id TEXT PRIMARY KEY, email TEXT UNIQUE NOT NULL, password TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS public.reminder_template (id TEXT PRIMARY KEY, user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE, name TEXT NOT NULL);
INSERT INTO public.users (id,email,password) VALUES ('u1','legacy@example.com','x');
INSERT INTO public.reminder_template (id,user_id,name) VALUES ('t1','u1','Legacy reminder');"

# --- 1. FRESH INSTALL | search_path=custom,public -------------------------------
note "1. FRESH INSTALL | $MIGRATION_FILE | search_path=custom,public"
DB="${DB_PREFIX}_fresh"
mkdb "$DB" || exit 1
sudo -u postgres psql -X -qAt -d "$DB" -c "CREATE SCHEMA custom;" >/dev/null 2>&1
RC=$(run_migration "$DB" "custom,public" "$WORK_DIR/1_fresh.out")
[ "$RC" = "0" ] && pass "fresh install completes (rc=0)" || fail "fresh install errored rc=$RC: $(tail -2 "$WORK_DIR"/1_fresh.out)"
PUB=$(q "$DB" "SELECT to_regclass('public.reminder_templates') IS NOT NULL;")
[ "$PUB" = "t" ] && pass "public.reminder_templates created" || fail "public.reminder_templates missing"
CUSTREM=$(q "$DB" "SELECT to_regclass('custom.reminders') IS NOT NULL;")
[ "$CUSTREM" = "t" ] && pass "reminders table created in first path schema (custom)" || fail "custom.reminders missing (search_path not honored)"

# --- 2. STRICT-PATH LEGACY UPGRADE | search_path=custom (public absent) ----------
# The scenario PR #2 repaired: previously the unqualified reminders.template_id FK
# aborted at line 225 with 'relation "reminder_templates" does not exist'.
note "2. STRICT-PATH LEGACY UPGRADE | legacy data in public.reminder_template | search_path=custom (public absent) — must COMPLETE"
DB="${DB_PREFIX}_legacy"
mkdb "$DB" || exit 1
sudo -u postgres psql -X -v ON_ERROR_STOP=1 -qAt -d "$DB" -c "$LEGACY_PRESQL" >/dev/null 2>&1
RC=$(run_migration "$DB" "custom" "$WORK_DIR/2_strict_legacy.out")
ROWS=$(q "$DB" "SELECT count(*) FROM public.reminder_templates;")
SING=$(q "$DB" "SELECT to_regclass('public.reminder_template') IS NULL;")
FKP=$(q "$DB" "SELECT count(*) FROM pg_constraint WHERE conrelid='public.reminder_templates'::regclass AND contype='f';")
FKTGT=$(q "$DB" "SELECT count(*) FROM pg_constraint c JOIN pg_class r ON c.conrelid=r.oid JOIN pg_namespace n ON r.relnamespace=n.oid WHERE n.nspname='custom' AND r.relname='reminders' AND c.contype='f' AND c.confrelid='public.reminder_templates'::regclass;")
[ "$RC" = "0" ] && pass "strict-path legacy upgrade completes (rc=0)" || fail "strict-path legacy upgrade errored rc=$RC: $(tail -3 "$WORK_DIR"/2_strict_legacy.out)"
[ "$ROWS" = "1" ] && pass "legacy row preserved in public.reminder_templates (count=1)" || fail "legacy row count=$ROWS"
[ "$SING" = "t" ] && pass "public.reminder_template renamed away" || fail "public.reminder_template still exists"
[ "${FKP:-0}" -ge 1 ] && pass "FKs preserved on reminder_templates (count=$FKP)" || fail "FKs missing on reminder_templates (count=${FKP:-0})"
[ "${FKTGT:-0}" = "1" ] && pass "reminders.template_id FK references public.reminder_templates" || fail "FK target wrong/absent (count=${FKTGT:-0})"
if grep -q 'relation "reminder_templates" does not exist' "$WORK_DIR"/2_strict_legacy.out; then
  fail "strict-path run still aborts on unqualified reminder_templates FK (pre-f0a7b42 defect)"
fi

# --- 3. CANONICAL RE-RUN | second pass on the upgraded DB -------------------------
note "3. CANONICAL RE-RUN | migration run a second time on the upgraded DB"
RC=$(run_migration "$DB" "custom" "$WORK_DIR/3_rerun.out")
ROWS=$(q "$DB" "SELECT count(*) FROM public.reminder_templates;")
[ "$RC" = "0" ] && pass "re-run completes idempotently (rc=0)" || fail "re-run errored rc=$RC: $(tail -3 "$WORK_DIR"/3_rerun.out)"
[ "$ROWS" = "1" ] && pass "no duplicates after re-run (count=1)" || fail "row count after re-run=$ROWS"

# --- 4. DUAL-TABLE STOP | both tables present --------------------------------------
note "4. DUAL-TABLE STOP | both public.reminder_template and public.reminder_templates exist — must abort safely"
DB="${DB_PREFIX}_dual"
mkdb "$DB" || exit 1
sudo -u postgres psql -X -v ON_ERROR_STOP=1 -qAt -d "$DB" -c "$LEGACY_PRESQL" >/dev/null 2>&1
sudo -u postgres psql -X -v ON_ERROR_STOP=1 -qAt -d "$DB" -c "CREATE TABLE public.reminder_templates (LIKE public.reminder_template INCLUDING ALL);" >/dev/null 2>&1
RC=$(run_migration "$DB" "custom,public" "$WORK_DIR/4_dual.out")
STRAND=$(q "$DB" "SELECT count(*) FROM public.reminder_template;")
[ "$RC" != "0" ] && pass "dual-table run aborts (rc=$RC)" || fail "dual-table run did NOT abort"
if grep -q "both public.reminder_template and public.reminder_templates exist" "$WORK_DIR"/4_dual.out; then
  pass "explicit dual-table stop message raised"
else
  fail "dual-table stop message missing: $(tail -3 "$WORK_DIR"/4_dual.out)"
fi
[ "$STRAND" = "1" ] && pass "legacy rows stranded safely (count=1, not destroyed)" || fail "stranded rows=$STRAND"

# --- summary ------------------------------------------------------------------------
printf '\n================ RESULT ================\n'
if [ "$FAILURES" -eq 0 ]; then
  echo "ALL MIGRATION REGRESSION CHECKS PASSED ($MIGRATION_FILE)"
  exit 0
else
  echo "$FAILURES MIGRATION REGRESSION CHECK(S) FAILED (logs kept in $WORK_DIR; re-run with KEEP_WORK=1)"
  exit 1
fi
