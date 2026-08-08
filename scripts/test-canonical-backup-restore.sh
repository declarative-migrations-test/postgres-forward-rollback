#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CANONICAL_SOURCE_DIR="${CANONICAL_SOURCE_DIR:-$ROOT/vendor/canonical-api-server.rs}"
DPM_BIN="${DPM_BIN:?DPM_BIN is required}"

SOURCE_ADMIN_URL="${SOURCE_ADMIN_URL:-postgres://postgres@127.0.0.1:5432/postgres}"
RESTORE_ADMIN_URL="${RESTORE_ADMIN_URL:-postgres://postgres@127.0.0.1:5433/postgres}"
SOURCE_DATABASE="${SOURCE_DATABASE:-canonical_quote_backup_source}"
RESTORE_DATABASE="${RESTORE_DATABASE:-canonical_quote_backup_restore}"

SOURCE_DB_ADMIN_URL="postgres://postgres@127.0.0.1:5432/${SOURCE_DATABASE}"
SOURCE_MIGRATOR_URL="postgres://canonical_cloud__quote__migrator@127.0.0.1:5432/${SOURCE_DATABASE}"
SOURCE_API_URL="postgres://canonical_cloud__quote__api_rw@127.0.0.1:5432/${SOURCE_DATABASE}"
RESTORE_DB_ADMIN_URL="postgres://postgres@127.0.0.1:5433/${RESTORE_DATABASE}"
RESTORE_MIGRATOR_URL="postgres://canonical_cloud__quote__migrator@127.0.0.1:5433/${RESTORE_DATABASE}"
RESTORE_API_URL="postgres://canonical_cloud__quote__api_rw@127.0.0.1:5433/${RESTORE_DATABASE}"
RESTORE_WEB_URL="postgres://canonical_cloud__quote__web_ro@127.0.0.1:5433/${RESTORE_DATABASE}"

ARTIFACTS="$ROOT/artifacts/canonical-backup-restore"
mkdir -p "$ARTIFACTS"
chmod 0777 "$ARTIFACTS"

cleanup_cluster() {
  local admin_url="$1"
  local database="$2"
  psql "$admin_url" -v ON_ERROR_STOP=1 \
    -c "DROP DATABASE IF EXISTS ${database} WITH (FORCE)" \
    >/dev/null 2>&1 || true
  for role in \
    canonical_cloud__quote__web_ro \
    canonical_cloud__quote__api_rw \
    canonical_cloud__quote__migrator
  do
    psql "$admin_url" -v ON_ERROR_STOP=1 \
      -c "DROP ROLE IF EXISTS ${role}" >/dev/null 2>&1 || true
  done
}

cleanup() {
  cleanup_cluster "$SOURCE_ADMIN_URL" "$SOURCE_DATABASE"
  cleanup_cluster "$RESTORE_ADMIN_URL" "$RESTORE_DATABASE"
}
trap cleanup EXIT
cleanup

source_version="$(psql "$SOURCE_ADMIN_URL" -Atqc "SHOW server_version_num")"
restore_version="$(psql "$RESTORE_ADMIN_URL" -Atqc "SHOW server_version_num")"
[[ "$source_version" == 17* ]]
[[ "$restore_version" == 18* ]]

psql "$SOURCE_ADMIN_URL" -v ON_ERROR_STOP=1 \
  -c "CREATE DATABASE ${SOURCE_DATABASE}" >/dev/null
psql "$RESTORE_ADMIN_URL" -v ON_ERROR_STOP=1 \
  -c "CREATE DATABASE ${RESTORE_DATABASE}" >/dev/null

psql "$SOURCE_DB_ADMIN_URL" -v ON_ERROR_STOP=1 \
  -f "$CANONICAL_SOURCE_DIR/db/bootstrap.sql" >/dev/null

"$DPM_BIN" apply \
  --source-sql "$CANONICAL_SOURCE_DIR/db/schema.sql" \
  --target "$SOURCE_MIGRATOR_URL" \
  --shadow "$SOURCE_ADMIN_URL" \
  --yes \
  >"$ARTIFACTS/source-apply.out"

psql "$SOURCE_DB_ADMIN_URL" -v ON_ERROR_STOP=1 \
  -f "$CANONICAL_SOURCE_DIR/db/grants.sql" >/dev/null

psql "$SOURCE_API_URL" -v ON_ERROR_STOP=1 >/dev/null <<'SQL'
BEGIN;
SET LOCAL app.current_subject = 'owner-a';
INSERT INTO canonical_cloud__quote.canonical_context (
    id, owner_subject, name, context_markdown, context_json
) VALUES (
    'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
    'owner-a',
    'Owner A production-like context',
    'Synthetic backup and restore fixture A',
    '{"region":"us-east-1","source":"backup-restore-test"}'::jsonb
);
INSERT INTO canonical_cloud__quote.canonical_quote (
    id,
    owner_subject,
    context_record_id,
    request_json,
    application_context_markdown,
    context_snapshot_markdown,
    context_snapshot_json,
    gemini_model,
    status,
    analysis_json
) VALUES (
    '11111111-1111-4111-8111-111111111111',
    'owner-a',
    'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
    '{"organizationName":"Owner A Example","frameworks":["soc2_type_2"],"answersVersion":1}'::jsonb,
    'Synthetic application context',
    'Synthetic backup and restore fixture A',
    '{"region":"us-east-1"}'::jsonb,
    'gemini-3.6-pro',
    'completed',
    '{"summary":"Synthetic ready estimate","currency":"USD"}'::jsonb
);
INSERT INTO canonical_cloud__quote.canonical_quote_event (
    quote_id, owner_subject, status, details_json
) VALUES (
    '11111111-1111-4111-8111-111111111111',
    'owner-a',
    'completed',
    '{"analysis_available":true}'::jsonb
);
INSERT INTO canonical_cloud__quote.canonical_model_attempt (
    id, quote_id, owner_subject, provider, model, status, finished_at
) VALUES (
    'aaaaaaaa-1111-4111-8111-111111111111',
    '11111111-1111-4111-8111-111111111111',
    'owner-a',
    'google-gemini',
    'gemini-3.6-pro',
    'completed',
    CURRENT_TIMESTAMP
);
COMMIT;

BEGIN;
SET LOCAL app.current_subject = 'owner-b';
INSERT INTO canonical_cloud__quote.canonical_context (
    id, owner_subject, name, context_markdown, context_json
) VALUES (
    'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
    'owner-b',
    'Owner B production-like context',
    'Synthetic backup and restore fixture B',
    '{"region":"us-west-2","source":"backup-restore-test"}'::jsonb
);
INSERT INTO canonical_cloud__quote.canonical_quote (
    id,
    owner_subject,
    context_record_id,
    request_json,
    application_context_markdown,
    context_snapshot_markdown,
    context_snapshot_json,
    gemini_model,
    status,
    analysis_json
) VALUES (
    '22222222-2222-4222-8222-222222222222',
    'owner-b',
    'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
    '{"organizationName":"Owner B Example","frameworks":["hipaa"],"answersVersion":1}'::jsonb,
    'Synthetic application context',
    'Synthetic backup and restore fixture B',
    '{"region":"us-west-2"}'::jsonb,
    'gemini-3.6-pro',
    'failed',
    NULL
);
INSERT INTO canonical_cloud__quote.canonical_quote_event (
    quote_id, owner_subject, status, details_json
) VALUES (
    '22222222-2222-4222-8222-222222222222',
    'owner-b',
    'failed',
    '{"analysis_available":false,"error_code":"synthetic_failure"}'::jsonb
);
INSERT INTO canonical_cloud__quote.canonical_model_attempt (
    id, quote_id, owner_subject, provider, model, status, error_code, finished_at
) VALUES (
    'bbbbbbbb-2222-4222-8222-222222222222',
    '22222222-2222-4222-8222-222222222222',
    'owner-b',
    'google-gemini',
    'gemini-3.6-pro',
    'failed',
    'synthetic_failure',
    CURRENT_TIMESTAMP
);
COMMIT;
SQL

source_counts="$(psql "$SOURCE_DB_ADMIN_URL" -Atqc "
  SELECT
    (SELECT count(*) FROM canonical_cloud__quote.canonical_context) || '|' ||
    (SELECT count(*) FROM canonical_cloud__quote.canonical_quote) || '|' ||
    (SELECT count(*) FROM canonical_cloud__quote.canonical_quote_event) || '|' ||
    (SELECT count(*) FROM canonical_cloud__quote.canonical_model_attempt)
")"
[[ "$source_counts" == "2|2|2|2" ]]

source_quote_hash="$(psql "$SOURCE_DB_ADMIN_URL" -Atqc "
  SELECT md5(string_agg(
    owner_subject || ':' || id::text || ':' || request_json::text || ':' ||
    coalesce(analysis_json::text, ''),
    '|' ORDER BY owner_subject, id
  ))
  FROM canonical_cloud__quote.canonical_quote
")"
[[ "$source_quote_hash" =~ ^[0-9a-f]{32}$ ]]

# Use engine-matched client binaries so the source dump and target restore are
# not accidentally certified by an older host package.
docker run --rm --network host \
  -v "$ARTIFACTS:/backup" \
  postgres:17 \
  pg_dump "$SOURCE_DB_ADMIN_URL" \
    --format=custom \
    --schema=canonical_cloud__quote \
    --no-owner \
    --no-acl \
    --file=/backup/canonical-quote.dump

test -s "$ARTIFACTS/canonical-quote.dump"
docker run --rm \
  -v "$ARTIFACTS:/backup" \
  postgres:18 \
  pg_restore --list /backup/canonical-quote.dump \
  >"$ARTIFACTS/canonical-quote.list"
for object in \
  canonical_context \
  canonical_quote \
  canonical_quote_event \
  canonical_model_attempt \
  canonical_context_owner_policy \
  canonical_quote_owner_policy
 do
  grep -q "$object" "$ARTIFACTS/canonical-quote.list"
done

# Bootstrap establishes the cluster roles and per-database role settings. The
# empty schema is removed before restore so the archive recreates every object
# under the reviewed migrator identity.
psql "$RESTORE_DB_ADMIN_URL" -v ON_ERROR_STOP=1 \
  -f "$CANONICAL_SOURCE_DIR/db/bootstrap.sql" >/dev/null
psql "$RESTORE_DB_ADMIN_URL" -v ON_ERROR_STOP=1 \
  -c "DROP SCHEMA canonical_cloud__quote CASCADE" >/dev/null

docker run --rm --network host \
  -v "$ARTIFACTS:/backup" \
  postgres:18 \
  pg_restore \
    --exit-on-error \
    --dbname="$RESTORE_DB_ADMIN_URL" \
    --no-owner \
    --no-acl \
    --role=canonical_cloud__quote__migrator \
    /backup/canonical-quote.dump

psql "$RESTORE_DB_ADMIN_URL" -v ON_ERROR_STOP=1 \
  -f "$CANONICAL_SOURCE_DIR/db/grants.sql" >/dev/null

"$DPM_BIN" diff \
  --source-sql "$CANONICAL_SOURCE_DIR/db/schema.sql" \
  --target "$RESTORE_MIGRATOR_URL" \
  --shadow "$RESTORE_ADMIN_URL" \
  --fail-on-diff \
  >"$ARTIFACTS/restored-diff.sql"

"$DPM_BIN" verify \
  --source-sql "$CANONICAL_SOURCE_DIR/db/schema.sql" \
  --target "$RESTORE_MIGRATOR_URL" \
  --shadow "$RESTORE_ADMIN_URL" \
  >"$ARTIFACTS/restored-verify.out"

test "$(psql "$RESTORE_DB_ADMIN_URL" -Atqc "
  SELECT count(*)
  FROM pg_class AS relation
  JOIN pg_namespace AS namespace
    ON namespace.oid = relation.relnamespace
  WHERE namespace.nspname = 'canonical_cloud__quote'
    AND relation.relkind IN ('r', 'p', 'S')
    AND pg_get_userbyid(relation.relowner)
        <> 'canonical_cloud__quote__migrator'
")" = "0"

test "$(psql "$RESTORE_DB_ADMIN_URL" -Atqc "
  SELECT count(*)
  FROM pg_class AS relation
  JOIN pg_namespace AS namespace
    ON namespace.oid = relation.relnamespace
  WHERE namespace.nspname = 'canonical_cloud__quote'
    AND relation.relname IN (
      'canonical_context',
      'canonical_quote',
      'canonical_quote_event',
      'canonical_model_attempt'
    )
    AND relation.relrowsecurity
    AND relation.relforcerowsecurity
")" = "4"

test "$(psql "$RESTORE_DB_ADMIN_URL" -Atqc "
  SELECT count(*)
  FROM pg_policies
  WHERE schemaname = 'canonical_cloud__quote'
")" = "4"

restore_counts="$(psql "$RESTORE_DB_ADMIN_URL" -Atqc "
  SELECT
    (SELECT count(*) FROM canonical_cloud__quote.canonical_context) || '|' ||
    (SELECT count(*) FROM canonical_cloud__quote.canonical_quote) || '|' ||
    (SELECT count(*) FROM canonical_cloud__quote.canonical_quote_event) || '|' ||
    (SELECT count(*) FROM canonical_cloud__quote.canonical_model_attempt)
")"
[[ "$restore_counts" == "$source_counts" ]]

restore_quote_hash="$(psql "$RESTORE_DB_ADMIN_URL" -Atqc "
  SELECT md5(string_agg(
    owner_subject || ':' || id::text || ':' || request_json::text || ':' ||
    coalesce(analysis_json::text, ''),
    '|' ORDER BY owner_subject, id
  ))
  FROM canonical_cloud__quote.canonical_quote
")"
[[ "$restore_quote_hash" == "$source_quote_hash" ]]

owner_a_visibility="$(psql "$RESTORE_API_URL" -Atq <<'SQL'
BEGIN;
SET LOCAL app.current_subject = 'owner-a';
SELECT
  (SELECT count(*) FROM canonical_cloud__quote.canonical_context) || '|' ||
  (SELECT count(*) FROM canonical_cloud__quote.canonical_quote) || '|' ||
  (SELECT count(*) FROM canonical_cloud__quote.canonical_quote_event) || '|' ||
  (SELECT count(*) FROM canonical_cloud__quote.canonical_model_attempt);
COMMIT;
SQL
)"
[[ "$owner_a_visibility" == "1|1|1|1" ]]

owner_b_visibility="$(psql "$RESTORE_API_URL" -Atq <<'SQL'
BEGIN;
SET LOCAL app.current_subject = 'owner-b';
SELECT
  (SELECT count(*) FROM canonical_cloud__quote.canonical_context) || '|' ||
  (SELECT count(*) FROM canonical_cloud__quote.canonical_quote) || '|' ||
  (SELECT count(*) FROM canonical_cloud__quote.canonical_quote_event) || '|' ||
  (SELECT count(*) FROM canonical_cloud__quote.canonical_model_attempt);
COMMIT;
SQL
)"
[[ "$owner_b_visibility" == "1|1|1|1" ]]

set +e
psql "$RESTORE_WEB_URL" -v ON_ERROR_STOP=1 \
  -c "SELECT count(*) FROM canonical_cloud__quote.canonical_quote" \
  >/dev/null 2>"$ARTIFACTS/restored-web-read.err"
web_status=$?
set -e
test "$web_status" -ne 0
grep -Eqi 'permission denied|no permission' "$ARTIFACTS/restored-web-read.err"

set +e
psql "$RESTORE_API_URL" -v ON_ERROR_STOP=1 \
  -c "CREATE TABLE canonical_cloud__quote.restore_must_not_create(id integer)" \
  >/dev/null 2>"$ARTIFACTS/restored-api-ddl.err"
api_ddl_status=$?
set -e
test "$api_ddl_status" -ne 0
grep -Eqi 'permission denied|no permission' "$ARTIFACTS/restored-api-ddl.err"

before_updated_at="$(psql "$RESTORE_DB_ADMIN_URL" -Atqc "
  SELECT extract(epoch FROM updated_at)
  FROM canonical_cloud__quote.canonical_context
  WHERE id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
")"
sleep 1
psql "$RESTORE_API_URL" -v ON_ERROR_STOP=1 >/dev/null <<'SQL'
BEGIN;
SET LOCAL app.current_subject = 'owner-a';
UPDATE canonical_cloud__quote.canonical_context
SET name = 'Owner A restored context'
WHERE id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
COMMIT;
SQL
after_updated_at="$(psql "$RESTORE_DB_ADMIN_URL" -Atqc "
  SELECT extract(epoch FROM updated_at)
  FROM canonical_cloud__quote.canonical_context
  WHERE id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
")"
python3 - "$before_updated_at" "$after_updated_at" <<'PY'
from decimal import Decimal
import sys
assert Decimal(sys.argv[2]) > Decimal(sys.argv[1])
PY

before_sequence="$(psql "$RESTORE_DB_ADMIN_URL" -Atqc "
  SELECT max(sequence_id)
  FROM canonical_cloud__quote.canonical_quote_event
")"
psql "$RESTORE_API_URL" -v ON_ERROR_STOP=1 >/dev/null <<'SQL'
BEGIN;
SET LOCAL app.current_subject = 'owner-a';
INSERT INTO canonical_cloud__quote.canonical_quote_event (
  quote_id, owner_subject, status, details_json
) VALUES (
  '11111111-1111-4111-8111-111111111111',
  'owner-a',
  'completed',
  '{"restored_sequence":true}'::jsonb
);
COMMIT;
SQL
after_sequence="$(psql "$RESTORE_DB_ADMIN_URL" -Atqc "
  SELECT max(sequence_id)
  FROM canonical_cloud__quote.canonical_quote_event
")"
python3 - "$before_sequence" "$after_sequence" <<'PY'
import sys
assert int(sys.argv[2]) > int(sys.argv[1])
PY

"$DPM_BIN" diff \
  --source-sql "$CANONICAL_SOURCE_DIR/db/schema.sql" \
  --target "$RESTORE_MIGRATOR_URL" \
  --shadow "$RESTORE_ADMIN_URL" \
  --fail-on-diff \
  >"$ARTIFACTS/final-diff.sql"

printf '%s\n' \
  "Canonical quote PostgreSQL 17 to 18 backup/restore certification passed"
