#!/usr/bin/env bash
set -euo pipefail
DPM="${DPM_BIN:?DPM_BIN is required}"
ADMIN="${POSTGRES_ADMIN_URL:-postgres://postgres@localhost:5432/postgres}"
DB="dm_postgres_rollback_e2e"
TARGET="postgres://postgres@localhost:5432/${DB}"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
artifacts="$root/artifacts"
mkdir -p "$artifacts"

cleanup() {
  psql "$ADMIN" -v ON_ERROR_STOP=1 -c "DROP DATABASE IF EXISTS ${DB} WITH (FORCE)" >/dev/null 2>&1 || true
}
trap cleanup EXIT
cleanup
psql "$ADMIN" -v ON_ERROR_STOP=1 -c "CREATE DATABASE ${DB}" >/dev/null

apply_and_prove() {
  local fixture="$1"; shift
  "$DPM" apply --source-sql "$root/fixtures/${fixture}.sql" --target "$TARGET" --shadow "$ADMIN" --yes "$@"
  "$DPM" diff --source-sql "$root/fixtures/${fixture}.sql" --target "$TARGET" --shadow "$ADMIN" --fail-on-diff "$@" >"$artifacts/${fixture}-converged.sql"
  "$DPM" verify --source-sql "$root/fixtures/${fixture}.sql" --target "$TARGET" --shadow "$ADMIN" "$@"
}

for cycle in 1 2 3; do
  apply_and_prove v1
  psql "$TARGET" -v ON_ERROR_STOP=1 -c "INSERT INTO app.accounts(id,email) VALUES ('acct-${cycle}','acct-${cycle}@example.test') ON CONFLICT (id) DO UPDATE SET email=EXCLUDED.email" >/dev/null

  apply_and_prove v2
  [[ "$(psql "$TARGET" -Atqc "SELECT status FROM app.accounts WHERE id='acct-${cycle}'")" == "active" ]]
  psql "$TARGET" -v ON_ERROR_STOP=1 -c "INSERT INTO app.account_events(event_id,account_id,event_type) VALUES ('evt-${cycle}','acct-${cycle}','cycle') ON CONFLICT (event_id) DO NOTHING" >/dev/null

  apply_and_prove v2

  set +e
  "$DPM" apply --source-sql "$root/fixtures/v1.sql" --target "$TARGET" --shadow "$ADMIN" --yes >"$artifacts/gated-${cycle}.out" 2>"$artifacts/gated-${cycle}.err"
  gated_status=$?
  set -e
  [[ "$gated_status" -eq 3 ]] || { echo "expected gated rollback exit 3, observed $gated_status" >&2; exit 1; }
  grep -q 'NOT CONVERGED' "$artifacts/gated-${cycle}.err"
  [[ "$(psql "$TARGET" -Atqc "SELECT count(*) FROM information_schema.tables WHERE table_schema='app' AND table_name='account_events'")" == "1" ]]

  apply_and_prove v1 --allow-destructive
  [[ "$(psql "$TARGET" -Atqc "SELECT count(*) FROM app.accounts WHERE id='acct-${cycle}'")" == "1" ]]
  [[ "$(psql "$TARGET" -Atqc "SELECT count(*) FROM information_schema.tables WHERE table_schema='app' AND table_name='account_events'")" == "0" ]]
  [[ "$(psql "$TARGET" -Atqc "SELECT count(*) FROM information_schema.columns WHERE table_schema='app' AND table_name='accounts' AND column_name IN ('status','updated_at')")" == "0" ]]
done

[[ "$(psql "$TARGET" -Atqc "SELECT count(*) FROM app.accounts")" == "3" ]]
echo "PostgreSQL rollback certification passed"
