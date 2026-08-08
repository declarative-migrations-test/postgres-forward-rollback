#!/usr/bin/env bash
set -euo pipefail
DPM="${DPM_BIN:?DPM_BIN is required}"
ADMIN="${POSTGRES_ADMIN_URL:-postgres://postgres:postgres@localhost:5432/postgres}"
DB="dm_postgres_forward_rollback"
TARGET="${POSTGRES_TARGET_URL:-postgres://postgres:postgres@localhost:5432/${DB}}"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cleanup() { psql "$ADMIN" -v ON_ERROR_STOP=1 -c "DROP DATABASE IF EXISTS ${DB} WITH (FORCE)" >/dev/null 2>&1 || true; }
trap cleanup EXIT
cleanup
psql "$ADMIN" -v ON_ERROR_STOP=1 -c "CREATE DATABASE ${DB}" >/dev/null

apply() {
  local schema="$1"; shift
  "$DPM" apply --source-sql "$root/fixtures/${schema}.sql" --target "$TARGET" --shadow "$ADMIN" --yes "$@"
  "$DPM" diff --source-sql "$root/fixtures/${schema}.sql" --target "$TARGET" --shadow "$ADMIN" --fail-on-diff "$@" >/dev/null
  "$DPM" verify --source-sql "$root/fixtures/${schema}.sql" --target "$TARGET" --shadow "$ADMIN" "$@"
}

for cycle in 1 2 3; do
  apply v1
  psql "$TARGET" -v ON_ERROR_STOP=1 -c "INSERT INTO app.accounts(id,email) VALUES ('acct-${cycle}','acct-${cycle}@example.test') ON CONFLICT (id) DO UPDATE SET email=EXCLUDED.email" >/dev/null
  apply v2
  test "$(psql "$TARGET" -Atqc "SELECT status FROM app.accounts WHERE id='acct-${cycle}'")" = "active"
  psql "$TARGET" -v ON_ERROR_STOP=1 -c "INSERT INTO app.account_events(event_id,account_id,event_type) VALUES ('evt-${cycle}','acct-${cycle}','cycle') ON CONFLICT (event_id) DO NOTHING" >/dev/null
  apply v2
  apply v1 --allow-destructive
  test "$(psql "$TARGET" -Atqc "SELECT count(*) FROM app.accounts WHERE id='acct-${cycle}'")" = "1"
  test "$(psql "$TARGET" -Atqc "SELECT count(*) FROM information_schema.tables WHERE table_schema='app' AND table_name='account_events'")" = "0"
  test "$(psql "$TARGET" -Atqc "SELECT count(*) FROM information_schema.columns WHERE table_schema='app' AND table_name='accounts' AND column_name IN ('status','updated_at')")" = "0"
done

echo "PostgreSQL forward/rollback certification passed"
