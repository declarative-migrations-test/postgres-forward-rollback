#!/usr/bin/env bash
set -euo pipefail

DPM="${DPM_BIN:?DPM_BIN is required}"
API_DIR="${CANONICAL_API_DIR:?CANONICAL_API_DIR is required}"
POSTGRES_MAJOR="${POSTGRES_MAJOR:?POSTGRES_MAJOR is required}"
POSTGRES_ADMIN_URL="${POSTGRES_ADMIN_URL:-postgres://postgres@127.0.0.1:5432/postgres}"
TEST_DATABASE="canonical_quote_v1_ready_pg${POSTGRES_MAJOR}"
TARGET_ADMIN_URL="postgres://postgres@127.0.0.1:5432/${TEST_DATABASE}"
MIGRATOR_URL="postgres://canonical_cloud__quote__migrator@127.0.0.1:5432/${TEST_DATABASE}"
API_URL="postgres://canonical_cloud__quote__api_rw@127.0.0.1:5432/${TEST_DATABASE}"
BASE_URL="http://127.0.0.1:18081"
TOKEN="0123456789abcdef0123456789abcdef"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARTIFACTS="${ROOT}/artifacts/canonical-quote-readiness/pg${POSTGRES_MAJOR}"
SERVER_LOG="${ARTIFACTS}/server.log"
SERVER_PID=""

mkdir -p "$ARTIFACTS"

cleanup() {
  if [[ -n "$SERVER_PID" ]]; then
    kill "$SERVER_PID" >/dev/null 2>&1 || true
    wait "$SERVER_PID" >/dev/null 2>&1 || true
  fi

  psql "$POSTGRES_ADMIN_URL" -v ON_ERROR_STOP=1 \
    -c "DROP DATABASE IF EXISTS ${TEST_DATABASE} WITH (FORCE)" \
    >/dev/null 2>&1 || true

  for role in \
    canonical_cloud__quote__web_ro \
    canonical_cloud__quote__api_rw \
    canonical_cloud__quote__migrator
  do
    psql "$POSTGRES_ADMIN_URL" -v ON_ERROR_STOP=1 \
      -c "DROP ROLE IF EXISTS ${role}" >/dev/null 2>&1 || true
  done
}
trap cleanup EXIT

expect_failure() {
  local name="$1"
  shift
  set +e
  "$@" >"${ARTIFACTS}/${name}.out" 2>"${ARTIFACTS}/${name}.err"
  local status=$?
  set -e
  if [[ "$status" -eq 0 ]]; then
    echo "${name}: command unexpectedly succeeded" >&2
    return 1
  fi
}

wait_for_status() {
  local expected="$1"
  local path="$2"
  local attempts="${3:-60}"
  local status=""
  for _ in $(seq 1 "$attempts"); do
    status="$(curl --silent --output /dev/null --write-out '%{http_code}' \
      "${BASE_URL}${path}" || true)"
    if [[ "$status" == "$expected" ]]; then
      return 0
    fi
    if [[ -n "$SERVER_PID" ]] && ! kill -0 "$SERVER_PID" >/dev/null 2>&1; then
      cat "$SERVER_LOG" >&2 || true
      return 1
    fi
    sleep 1
  done
  echo "${path}: expected HTTP ${expected}, observed ${status}" >&2
  cat "$SERVER_LOG" >&2 || true
  return 1
}

cleanup
psql "$POSTGRES_ADMIN_URL" -v ON_ERROR_STOP=1 \
  -c "CREATE DATABASE ${TEST_DATABASE}" >/dev/null

psql "$TARGET_ADMIN_URL" -v ON_ERROR_STOP=1 \
  -f "$API_DIR/db/bootstrap.sql" >/dev/null

"$DPM" apply \
  --source-sql "$API_DIR/db/schema.sql" \
  --target "$MIGRATOR_URL" \
  --shadow "$POSTGRES_ADMIN_URL" \
  --yes \
  >"${ARTIFACTS}/initial-apply.out"

"$DPM" diff \
  --source-sql "$API_DIR/db/schema.sql" \
  --target "$MIGRATOR_URL" \
  --shadow "$POSTGRES_ADMIN_URL" \
  --fail-on-diff \
  >"${ARTIFACTS}/initial-diff.sql"

"$DPM" verify \
  --source-sql "$API_DIR/db/schema.sql" \
  --target "$MIGRATOR_URL" \
  --shadow "$POSTGRES_ADMIN_URL" \
  >"${ARTIFACTS}/initial-verify.out"

psql "$TARGET_ADMIN_URL" -v ON_ERROR_STOP=1 \
  -f "$API_DIR/db/grants.sql" >/dev/null

# The runtime role must fail closed when no transaction-local subject exists.
expect_failure "missing-subject" \
  psql "$API_URL" -v ON_ERROR_STOP=1 -c \
  "INSERT INTO canonical_cloud__quote.canonical_context
     (id, owner_subject, name, context_json)
   VALUES
     ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
      'owner-without-subject',
      'must fail',
      '{}'::jsonb)"

# Seed an owner-scoped quote that remains present through drift and repair.
psql "$API_URL" -v ON_ERROR_STOP=1 >/dev/null <<'SQL'
BEGIN;
SET LOCAL app.current_subject = 'owner-a';
INSERT INTO canonical_cloud__quote.canonical_context (
    id,
    owner_subject,
    name,
    context_markdown,
    context_json
)
VALUES (
    '11111111-1111-4111-8111-111111111111',
    'owner-a',
    'Owner A context',
    '# Owner A',
    '{"region":"us"}'::jsonb
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
    status
)
VALUES (
    '22222222-2222-4222-8222-222222222222',
    'owner-a',
    '11111111-1111-4111-8111-111111111111',
    '{"frameworks":["soc2"],"organizationName":"Owner A"}'::jsonb,
    '# application',
    '# Owner A',
    '{"region":"us"}'::jsonb,
    'gemini-3.6-flash',
    'queued'
);
COMMIT;
SQL

# These rows satisfy the owner-B RLS predicate but must fail the composite
# owner foreign keys because the referenced quote belongs to owner A.
set +e
psql "$API_URL" -v ON_ERROR_STOP=1 \
  >"${ARTIFACTS}/cross-owner-event.out" \
  2>"${ARTIFACTS}/cross-owner-event.err" <<'SQL'
BEGIN;
SET LOCAL app.current_subject = 'owner-b';
INSERT INTO canonical_cloud__quote.canonical_quote_event (
    quote_id,
    owner_subject,
    status,
    details_json
)
VALUES (
    '22222222-2222-4222-8222-222222222222',
    'owner-b',
    'queued',
    '{}'::jsonb
);
COMMIT;
SQL
cross_owner_event_status=$?
set -e
test "$cross_owner_event_status" -ne 0
grep -Eqi 'foreign key|violates' "${ARTIFACTS}/cross-owner-event.err"

set +e
psql "$API_URL" -v ON_ERROR_STOP=1 \
  >"${ARTIFACTS}/cross-owner-model.out" \
  2>"${ARTIFACTS}/cross-owner-model.err" <<'SQL'
BEGIN;
SET LOCAL app.current_subject = 'owner-b';
INSERT INTO canonical_cloud__quote.canonical_model_attempt (
    id,
    quote_id,
    owner_subject,
    model,
    status
)
VALUES (
    '33333333-3333-4333-8333-333333333333',
    '22222222-2222-4222-8222-222222222222',
    'owner-b',
    'gemini-3.6-flash',
    'started'
);
COMMIT;
SQL
cross_owner_model_status=$?
set -e
test "$cross_owner_model_status" -ne 0
grep -Eqi 'foreign key|violates' "${ARTIFACTS}/cross-owner-model.err"

# JSON and model-state checks are database invariants, not only API validation.
set +e
psql "$API_URL" -v ON_ERROR_STOP=1 \
  >"${ARTIFACTS}/json-shape.out" \
  2>"${ARTIFACTS}/json-shape.err" <<'SQL'
BEGIN;
SET LOCAL app.current_subject = 'owner-a';
INSERT INTO canonical_cloud__quote.canonical_context (
    id,
    owner_subject,
    name,
    context_json
)
VALUES (
    '44444444-4444-4444-8444-444444444444',
    'owner-a',
    'Invalid JSON shape',
    '[]'::jsonb
);
COMMIT;
SQL
json_shape_status=$?
set -e
test "$json_shape_status" -ne 0
grep -Eqi 'check constraint|violates' "${ARTIFACTS}/json-shape.err"

set +e
psql "$API_URL" -v ON_ERROR_STOP=1 \
  >"${ARTIFACTS}/model-state.out" \
  2>"${ARTIFACTS}/model-state.err" <<'SQL'
BEGIN;
SET LOCAL app.current_subject = 'owner-a';
INSERT INTO canonical_cloud__quote.canonical_model_attempt (
    id,
    quote_id,
    owner_subject,
    model,
    status,
    finished_at
)
VALUES (
    '55555555-5555-4555-8555-555555555555',
    '22222222-2222-4222-8222-222222222222',
    'owner-a',
    'gemini-3.6-flash',
    'started',
    CURRENT_TIMESTAMP
);
COMMIT;
SQL
model_state_status=$?
set -e
test "$model_state_status" -ne 0
grep -Eqi 'check constraint|violates' "${ARTIFACTS}/model-state.err"

# Give the HTTP API a separate active context.
psql "$API_URL" -v ON_ERROR_STOP=1 >/dev/null <<'SQL'
BEGIN;
SET LOCAL app.current_subject = 'owner-api';
INSERT INTO canonical_cloud__quote.canonical_context (
    id,
    owner_subject,
    name,
    context_markdown,
    context_json
)
VALUES (
    '66666666-6666-4666-8666-666666666666',
    'owner-api',
    'API context',
    '# API context',
    '{"region":"us","program":"quote-v1"}'::jsonb
);
COMMIT;
SQL

DATABASE_URL="$API_URL" \
CANONICAL_INTERNAL_AUTH_TOKEN="$TOKEN" \
BIND_ADDRESS="127.0.0.1:18081" \
RUST_LOG="canonical_api_server=info" \
"$API_DIR/target/debug/canonical-api-server" \
  >"$SERVER_LOG" 2>&1 &
SERVER_PID="$!"

wait_for_status "200" "/healthz"
wait_for_status "200" "/readyz"

curl --silent --fail "${BASE_URL}/healthz" >"${ARTIFACTS}/health.json"
python3 - "${ARTIFACTS}/health.json" <<'PY'
import json
import sys

value = json.load(open(sys.argv[1]))
assert value["status"] == "ok"
assert value["databaseConfigured"] is True
assert value["geminiConfigured"] is False
assert value["geminiModel"] == "gemini-3.6-flash"
PY

curl --silent --fail "${BASE_URL}/readyz" >"${ARTIFACTS}/ready.json"
python3 - "${ARTIFACTS}/ready.json" <<'PY'
import json
import sys

value = json.load(open(sys.argv[1]))
assert value["status"] == "ready"
assert value["databaseReady"] is True
PY

# The immutable canonical fixture is the external wire contract.
create_status="$(
  curl --silent --show-error \
    --output "${ARTIFACTS}/quote-create.json" \
    --write-out '%{http_code}' \
    --request POST \
    --header 'content-type: application/json' \
    --header "x-canonical-internal-token: ${TOKEN}" \
    --header 'x-canonical-subject: owner-api' \
    --data-binary "@${API_DIR}/fixtures/quote/v1/request.json" \
    "${BASE_URL}/api/v1/quotes"
)"
test "$create_status" = "202"

quote_id="$(
  python3 - "${ARTIFACTS}/quote-create.json" <<'PY'
import json
import sys
import uuid

value = json.load(open(sys.argv[1]))
quote_id = value["quoteId"]
uuid.UUID(quote_id)
assert value["status"] == "queued"
assert value["streamUrl"] == f"/api/v1/quotes/{quote_id}/events"
assert value["createdAt"].endswith("Z")
assert set(value) == {"quoteId", "status", "streamUrl", "createdAt"}
print(quote_id)
PY
)"

# Server-owned context fields and unknown fields are rejected by the canonical
# request parser rather than being accepted and ignored.
python3 - "$API_DIR/fixtures/quote/v1/request.json" \
  "${ARTIFACTS}/quote-forbidden-context.json" <<'PY'
import json
import sys

value = json.load(open(sys.argv[1]))
value["contextRecordId"] = "attacker-selected"
json.dump(value, open(sys.argv[2], "w"))
PY

test "$(
  curl --silent --show-error \
    --output "${ARTIFACTS}/quote-forbidden-context-response.json" \
    --write-out '%{http_code}' \
    --request POST \
    --header 'content-type: application/json' \
    --header "x-canonical-internal-token: ${TOKEN}" \
    --header 'x-canonical-subject: owner-api' \
    --data-binary "@${ARTIFACTS}/quote-forbidden-context.json" \
    "${BASE_URL}/api/v1/quotes"
)" = "400"

read_status=""
for _ in $(seq 1 30); do
  read_status="$(
    curl --silent --show-error \
      --output "${ARTIFACTS}/quote-read.json" \
      --write-out '%{http_code}' \
      --header "x-canonical-internal-token: ${TOKEN}" \
      --header 'x-canonical-subject: owner-api' \
      "${BASE_URL}/api/v1/quotes/${quote_id}"
  )"
  if [[ "$read_status" == "200" ]]; then
    break
  fi
  sleep 1
done
test "$read_status" = "200"
python3 - "${ARTIFACTS}/quote-read.json" <<'PY'
import json
import sys

value = json.load(open(sys.argv[1]))
assert value["persistence"] == "postgres"
assert value["gemini_model"] == "gemini-3.6-flash"
assert value["organization_name"] == "Example Company"
PY

# Compatibility aliases remain readable while the canonical route is primary.
test "$(
  curl --silent --output /dev/null --write-out '%{http_code}' \
    --header "x-canonical-internal-token: ${TOKEN}" \
    --header 'x-canonical-subject: owner-api' \
    "${BASE_URL}/v1/quotes/${quote_id}"
)" = "200"

test "$(
  curl --silent --output /dev/null --write-out '%{http_code}' \
    --header "x-canonical-internal-token: ${TOKEN}" \
    --header 'x-canonical-subject: owner-b' \
    "${BASE_URL}/api/v1/quotes/${quote_id}"
)" = "404"

# Confirm the canonical wire object and model are what PostgreSQL stored.
test "$(
  psql "$TARGET_ADMIN_URL" -Atqc \
    "SELECT request_json->>'organizationName'
     FROM canonical_cloud__quote.canonical_quote
     WHERE id = '${quote_id}'"
)" = "Example Company"

test "$(
  psql "$TARGET_ADMIN_URL" -Atqc \
    "SELECT request_json->>'contactEmail'
     FROM canonical_cloud__quote.canonical_quote
     WHERE id = '${quote_id}'"
)" = "taylor@example.com"

test "$(
  psql "$TARGET_ADMIN_URL" -Atqc \
    "SELECT gemini_model
     FROM canonical_cloud__quote.canonical_quote
     WHERE id = '${quote_id}'"
)" = "gemini-3.6-flash"

# Readiness must reject a privileged runtime identity even while the database
# remains reachable.
psql "$POSTGRES_ADMIN_URL" -v ON_ERROR_STOP=1 \
  -c "ALTER ROLE canonical_cloud__quote__api_rw BYPASSRLS" >/dev/null
wait_for_status "503" "/readyz"
psql "$POSTGRES_ADMIN_URL" -v ON_ERROR_STOP=1 \
  -c "ALTER ROLE canonical_cloud__quote__api_rw NOBYPASSRLS" >/dev/null
wait_for_status "200" "/readyz"

# Readiness must also reject policy drift. DPM must detect and repair the exact
# desired schema while preserving all quote data.
psql "$TARGET_ADMIN_URL" -v ON_ERROR_STOP=1 \
  -c "DROP POLICY canonical_quote_owner_policy ON canonical_cloud__quote.canonical_quote" \
  >/dev/null
wait_for_status "503" "/readyz"

set +e
"$DPM" diff \
  --source-sql "$API_DIR/db/schema.sql" \
  --target "$MIGRATOR_URL" \
  --shadow "$POSTGRES_ADMIN_URL" \
  --fail-on-diff \
  >"${ARTIFACTS}/policy-drift.sql" \
  2>"${ARTIFACTS}/policy-drift.err"
drift_status=$?
set -e
test "$drift_status" -eq 2
grep -Eqi 'canonical_quote_owner_policy|CREATE POLICY' \
  "${ARTIFACTS}/policy-drift.sql" "${ARTIFACTS}/policy-drift.err"

"$DPM" apply \
  --source-sql "$API_DIR/db/schema.sql" \
  --target "$MIGRATOR_URL" \
  --shadow "$POSTGRES_ADMIN_URL" \
  --yes \
  >"${ARTIFACTS}/policy-repair.out"

"$DPM" diff \
  --source-sql "$API_DIR/db/schema.sql" \
  --target "$MIGRATOR_URL" \
  --shadow "$POSTGRES_ADMIN_URL" \
  --fail-on-diff \
  >"${ARTIFACTS}/final-diff.sql"

"$DPM" verify \
  --source-sql "$API_DIR/db/schema.sql" \
  --target "$MIGRATOR_URL" \
  --shadow "$POSTGRES_ADMIN_URL" \
  >"${ARTIFACTS}/final-verify.out"

psql "$TARGET_ADMIN_URL" -v ON_ERROR_STOP=1 \
  -f "$API_DIR/db/grants.sql" >/dev/null

wait_for_status "200" "/readyz"

test "$(
  psql "$TARGET_ADMIN_URL" -Atqc \
    "SELECT count(*) FROM canonical_cloud__quote.canonical_quote
     WHERE id = '${quote_id}'
       AND gemini_model = 'gemini-3.6-flash'
       AND request_json->>'organizationName' = 'Example Company'"
)" = "1"

test "$(
  psql "$TARGET_ADMIN_URL" -Atqc \
    "SELECT count(*) FROM canonical_cloud__quote.canonical_quote
     WHERE id = '22222222-2222-4222-8222-222222222222'"
)" = "1"

printf \
  'Canonical quote-v1 exact-head PostgreSQL %s readiness certification passed.\n' \
  "$POSTGRES_MAJOR"
