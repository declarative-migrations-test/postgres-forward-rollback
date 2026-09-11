#!/usr/bin/env bash
set -euo pipefail

DPM="${DPM_BIN:?DPM_BIN is required}"
API_DIR="${CANONICAL_API_DIR:?CANONICAL_API_DIR is required}"
ADMIN="${POSTGRES_ADMIN_URL:-postgres://postgres:quote-test@localhost:5432/postgres}"
PG_MAJOR="${POSTGRES_MAJOR:?POSTGRES_MAJOR is required}"
DB="canonical_quote_pg${PG_MAJOR}"
TARGET="postgres://postgres:quote-test@localhost:5432/${DB}"
RUNTIME="postgres://canonical_api_server:runtime-test@localhost:5432/${DB}"
SERVER_LOG="${RUNNER_TEMP:-/tmp}/canonical-quote-pg${PG_MAJOR}.log"
SERVER_PID=""
TOKEN="0123456789abcdef0123456789abcdef"
BASE_URL="http://127.0.0.1:18081"

cleanup() {
  if [[ -n "$SERVER_PID" ]]; then
    kill "$SERVER_PID" >/dev/null 2>&1 || true
    wait "$SERVER_PID" >/dev/null 2>&1 || true
  fi
  psql "$ADMIN" -v ON_ERROR_STOP=1 -c "DROP DATABASE IF EXISTS ${DB} WITH (FORCE)" >/dev/null 2>&1 || true
  psql "$ADMIN" -v ON_ERROR_STOP=1 -c "DROP ROLE IF EXISTS canonical_api_server" >/dev/null 2>&1 || true
}
trap cleanup EXIT
cleanup

psql "$ADMIN" -v ON_ERROR_STOP=1 <<SQL >/dev/null
CREATE ROLE canonical_api_server
  LOGIN
  PASSWORD 'runtime-test'
  NOSUPERUSER
  NOCREATEDB
  NOCREATEROLE
  NOREPLICATION
  NOBYPASSRLS;
CREATE DATABASE ${DB};
SQL

"$DPM" apply \
  --source-sql "$API_DIR/db/schema.sql" \
  --target "$TARGET" \
  --shadow "$ADMIN" \
  --yes
"$DPM" diff \
  --source-sql "$API_DIR/db/schema.sql" \
  --target "$TARGET" \
  --shadow "$ADMIN" \
  --fail-on-diff \
  >/dev/null
"$DPM" verify \
  --source-sql "$API_DIR/db/schema.sql" \
  --target "$TARGET" \
  --shadow "$ADMIN"
psql "$TARGET" -v ON_ERROR_STOP=1 -f "$API_DIR/db/runtime-grants.sql" >/dev/null

# Runtime writes must fail closed until a transaction-local owner is set.
if psql "$RUNTIME" -v ON_ERROR_STOP=1 <<'SQL' >/dev/null 2>&1
INSERT INTO canonical_context (
  id, owner_subject, name, context_markdown, context_json
) VALUES (
  'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
  'owner-without-session',
  'invalid',
  '',
  '{}'::jsonb
);
SQL
then
  echo "runtime insert unexpectedly succeeded without app.current_subject" >&2
  exit 1
fi

psql "$RUNTIME" -v ON_ERROR_STOP=1 <<'SQL' >/dev/null
BEGIN;
SELECT set_config('app.current_subject', 'owner-a', true);
INSERT INTO canonical_context (
  id, owner_subject, name, context_markdown, context_json
) VALUES (
  '11111111-1111-4111-8111-111111111111',
  'owner-a',
  'Owner A context',
  '# Owner A',
  '{"region":"us"}'::jsonb
);
INSERT INTO canonical_quote (
  id,
  owner_subject,
  context_record_id,
  request_json,
  application_context_markdown,
  context_snapshot_markdown,
  context_snapshot_json,
  gemini_model,
  status
) VALUES (
  '22222222-2222-4222-8222-222222222222',
  'owner-a',
  '11111111-1111-4111-8111-111111111111',
  '{"frameworks":["soc2"],"organization":{"employee_count":42,"industry":"Software","legal_name":"Owner A"}}'::jsonb,
  '# application',
  '# Owner A',
  '{"region":"us"}'::jsonb,
  'gemini-3.6-pro',
  'queued'
);
INSERT INTO canonical_quote_event (
  quote_id, owner_subject, status, details_json
) VALUES (
  '22222222-2222-4222-8222-222222222222',
  'owner-a',
  'queued',
  '{}'::jsonb
);
INSERT INTO canonical_model_attempt (
  id, quote_id, owner_subject, model, status
) VALUES (
  '33333333-3333-4333-8333-333333333333',
  '22222222-2222-4222-8222-222222222222',
  'owner-a',
  'gemini-3.6-pro',
  'started'
);
UPDATE canonical_model_attempt
SET status = 'completed', finished_at = CURRENT_TIMESTAMP
WHERE id = '33333333-3333-4333-8333-333333333333';
COMMIT;
SQL

# A caller cannot pair its own RLS-valid owner value with another owner's quote.
if psql "$RUNTIME" -v ON_ERROR_STOP=1 <<'SQL' >/dev/null 2>&1
BEGIN;
SELECT set_config('app.current_subject', 'owner-b', true);
INSERT INTO canonical_quote_event (
  quote_id, owner_subject, status, details_json
) VALUES (
  '22222222-2222-4222-8222-222222222222',
  'owner-b',
  'queued',
  '{}'::jsonb
);
COMMIT;
SQL
then
  echo "cross-owner quote event unexpectedly succeeded" >&2
  exit 1
fi

if psql "$RUNTIME" -v ON_ERROR_STOP=1 <<'SQL' >/dev/null 2>&1
BEGIN;
SELECT set_config('app.current_subject', 'owner-b', true);
INSERT INTO canonical_model_attempt (
  id, quote_id, owner_subject, model, status
) VALUES (
  '44444444-4444-4444-8444-444444444444',
  '22222222-2222-4222-8222-222222222222',
  'owner-b',
  'gemini-3.6-pro',
  'started'
);
COMMIT;
SQL
then
  echo "cross-owner model attempt unexpectedly succeeded" >&2
  exit 1
fi

owner_a_count="$(psql "$RUNTIME" -Atv ON_ERROR_STOP=1 <<'SQL'
BEGIN;
SELECT set_config('app.current_subject', 'owner-a', true);
SELECT count(*) FROM canonical_quote;
COMMIT;
SQL
)"
owner_a_count="$(printf '%s\n' "$owner_a_count" | grep -E '^[0-9]+$' | tail -1)"
test "$owner_a_count" = "1"

owner_b_count="$(psql "$RUNTIME" -Atv ON_ERROR_STOP=1 <<'SQL'
BEGIN;
SELECT set_config('app.current_subject', 'owner-b', true);
SELECT count(*) FROM canonical_quote;
COMMIT;
SQL
)"
owner_b_count="$(printf '%s\n' "$owner_b_count" | grep -E '^[0-9]+$' | tail -1)"
test "$owner_b_count" = "0"

test "$(psql "$RUNTIME" -Atqc "SELECT has_table_privilege(current_user, 'canonical_quote', 'DELETE')")" = "f"
test "$(psql "$RUNTIME" -Atqc "SELECT has_table_privilege(current_user, 'canonical_quote_event', 'UPDATE')")" = "f"
test "$(psql "$RUNTIME" -Atqc "SELECT has_sequence_privilege(current_user, 'canonical_quote_event_sequence_id_seq', 'USAGE')")" = "t"

# Give the API owner an active context, then boot the exact candidate binary as
# the restricted runtime role.
psql "$RUNTIME" -v ON_ERROR_STOP=1 <<'SQL' >/dev/null
BEGIN;
SELECT set_config('app.current_subject', 'owner-api', true);
INSERT INTO canonical_context (
  id, owner_subject, name, context_markdown, context_json
) VALUES (
  '55555555-5555-4555-8555-555555555555',
  'owner-api',
  'API context',
  '# API context',
  '{"region":"us"}'::jsonb
);
COMMIT;
SQL

DATABASE_URL="$RUNTIME" \
CANONICAL_INTERNAL_AUTH_TOKEN="$TOKEN" \
BIND_ADDRESS="127.0.0.1:18081" \
GEMINI_MODEL="gemini-3.6-pro" \
RUST_LOG="canonical_api_server=info" \
"$API_DIR/target/debug/canonical-api-server" >"$SERVER_LOG" 2>&1 &
SERVER_PID="$!"

for _ in $(seq 1 60); do
  if curl --silent --fail "$BASE_URL/readyz" >"${RUNNER_TEMP:-/tmp}/ready.json"; then
    break
  fi
  if ! kill -0 "$SERVER_PID" >/dev/null 2>&1; then
    cat "$SERVER_LOG" >&2
    exit 1
  fi
  sleep 1
done
curl --silent --fail "$BASE_URL/healthz" >/dev/null
curl --silent --fail "$BASE_URL/readyz" \
  | python3 -c 'import json,sys; value=json.load(sys.stdin); assert value["status"] == "ready"; assert value["databaseReady"] is True'

create_status="$(curl --silent --show-error --output "${RUNNER_TEMP:-/tmp}/quote-create.json" --write-out '%{http_code}' \
  --request POST \
  --header 'content-type: application/json' \
  --header "x-canonical-internal-token: ${TOKEN}" \
  --header 'x-canonical-subject: owner-api' \
  --data '{"frameworks":["soc2","hipaa"],"organization":{"employee_count":42,"industry":"Software","legal_name":"API Owner"},"target_date":"2027-01-15"}' \
  "$BASE_URL/v1/quotes")"
test "$create_status" = "202"
quote_id="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["quote_id"])' "${RUNNER_TEMP:-/tmp}/quote-create.json")"
python3 -c 'import uuid,sys; uuid.UUID(sys.argv[1])' "$quote_id"

for _ in $(seq 1 30); do
  read_status="$(curl --silent --show-error --output "${RUNNER_TEMP:-/tmp}/quote-read.json" --write-out '%{http_code}' \
    --header "x-canonical-internal-token: ${TOKEN}" \
    --header 'x-canonical-subject: owner-api' \
    "$BASE_URL/v1/quotes/${quote_id}")"
  if [[ "$read_status" == "200" ]]; then
    break
  fi
  sleep 1
done
test "$read_status" = "200"
python3 -c 'import json,sys; value=json.load(open(sys.argv[1])); assert value["persistence"] == "postgres"' "${RUNNER_TEMP:-/tmp}/quote-read.json"

test "$(curl --silent --output /dev/null --write-out '%{http_code}' \
  --header "x-canonical-internal-token: ${TOKEN}" \
  --header 'x-canonical-subject: owner-b' \
  "$BASE_URL/v1/quotes/${quote_id}")" = "404"

# Prove the readiness endpoint is schema-aware and that dpm detects and repairs
# policy drift without losing quote data.
psql "$TARGET" -v ON_ERROR_STOP=1 -c "DROP POLICY canonical_quote_owner_policy ON canonical_quote" >/dev/null

test "$(curl --silent --output /dev/null --write-out '%{http_code}' "$BASE_URL/readyz")" = "503"
if "$DPM" diff \
  --source-sql "$API_DIR/db/schema.sql" \
  --target "$TARGET" \
  --shadow "$ADMIN" \
  --fail-on-diff \
  >"${RUNNER_TEMP:-/tmp}/canonical-quote-drift.sql" 2>&1
then
  echo "dpm failed to detect removed RLS policy" >&2
  exit 1
fi

"$DPM" apply \
  --source-sql "$API_DIR/db/schema.sql" \
  --target "$TARGET" \
  --shadow "$ADMIN" \
  --yes
"$DPM" diff \
  --source-sql "$API_DIR/db/schema.sql" \
  --target "$TARGET" \
  --shadow "$ADMIN" \
  --fail-on-diff \
  >/dev/null
"$DPM" verify \
  --source-sql "$API_DIR/db/schema.sql" \
  --target "$TARGET" \
  --shadow "$ADMIN"

for _ in $(seq 1 30); do
  if curl --silent --fail "$BASE_URL/readyz" >/dev/null; then
    break
  fi
  sleep 1
done
curl --silent --fail "$BASE_URL/readyz" >/dev/null

test "$(psql "$TARGET" -Atqc "SELECT count(*) FROM canonical_quote WHERE id='${quote_id}'")" = "1"
printf 'Canonical quote PostgreSQL %s certification passed.\n' "$PG_MAJOR"
