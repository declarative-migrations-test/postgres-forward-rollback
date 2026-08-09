#!/usr/bin/env bash
set -euo pipefail

DPM="${DPM_BIN:?DPM_BIN is required}"
API_DIR="${CANONICAL_API_DIR:?CANONICAL_API_DIR is required}"
POSTGRES_MAJOR="${POSTGRES_MAJOR:?POSTGRES_MAJOR is required}"
POSTGRES_ADMIN_URL="${POSTGRES_ADMIN_URL:-postgres://postgres@127.0.0.1:5432/postgres}"
TEST_DATABASE="canonical_quote_current_pg${POSTGRES_MAJOR}"
TARGET_ADMIN_URL="postgres://postgres@127.0.0.1:5432/${TEST_DATABASE}"
MIGRATOR_URL="postgres://canonical_cloud__quote__migrator@127.0.0.1:5432/${TEST_DATABASE}"
API_URL="postgres://canonical_cloud__quote__api_rw@127.0.0.1:5432/${TEST_DATABASE}"
BASE_URL="http://127.0.0.1:18082"
TOKEN="0123456789abcdef0123456789abcdef"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARTIFACTS="${ROOT}/artifacts/canonical-quote-current/pg${POSTGRES_MAJOR}"
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

# The operation ledger is owner-scoped and append-only for the runtime role.
test "$(psql "$TARGET_ADMIN_URL" -Atqc \
  "SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
   WHERE n.nspname='canonical_cloud__quote'
     AND c.relname='canonical_quote_operation'")" = "1"
test "$(psql "$TARGET_ADMIN_URL" -Atqc \
  "SELECT relrowsecurity::int || ':' || relforcerowsecurity::int
   FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
   WHERE n.nspname='canonical_cloud__quote'
     AND c.relname='canonical_quote_operation'")" = "1:1"
test "$(psql "$TARGET_ADMIN_URL" -Atqc \
  "SELECT has_table_privilege('canonical_cloud__quote__api_rw',
    'canonical_cloud__quote.canonical_quote_operation','SELECT')::int || ':' ||
    has_table_privilege('canonical_cloud__quote__api_rw',
    'canonical_cloud__quote.canonical_quote_operation','INSERT')::int || ':' ||
    has_table_privilege('canonical_cloud__quote__api_rw',
    'canonical_cloud__quote.canonical_quote_operation','UPDATE')::int || ':' ||
    has_table_privilege('canonical_cloud__quote__api_rw',
    'canonical_cloud__quote.canonical_quote_operation','DELETE')::int")" = "1:1:0:0"

# Give the API one owner-selected active context. The browser cannot select its id.
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
    'API current-v1 context',
    '# Current v1 context',
    '{"program":"quote-v1","synthetic":true}'::jsonb
);
COMMIT;
SQL

DATABASE_URL="$API_URL" \
CANONICAL_INTERNAL_AUTH_TOKEN="$TOKEN" \
BIND_ADDRESS="127.0.0.1:18082" \
RUST_LOG="canonical_api_server=info" \
"$API_DIR/target/debug/canonical-api-server" \
  >"$SERVER_LOG" 2>&1 &
SERVER_PID="$!"

wait_for_status "200" "/healthz"
wait_for_status "200" "/readyz"

create_status="$(curl --silent --show-error \
  --output "${ARTIFACTS}/create.json" \
  --write-out '%{http_code}' \
  --request POST \
  --header 'content-type: application/json' \
  --header 'idempotency-key: quote:test-current-create' \
  --header "x-canonical-internal-token: ${TOKEN}" \
  --header 'x-canonical-subject: owner-api' \
  --data-binary "@${API_DIR}/fixtures/quote-v1/create-request.json" \
  "${BASE_URL}/api/v1/quotes")"
test "$create_status" = "202"
quote_id="$(python3 - "${ARTIFACTS}/create.json" <<'PY'
import json, sys, uuid
value=json.load(open(sys.argv[1]))
quote_id=value['quoteId']
uuid.UUID(quote_id)
assert value['status']=='queued'
assert value['streamUrl']==f'/api/v1/quotes/{quote_id}/events'
assert value['createdAt'].endswith('Z')
assert set(value)=={'quoteId','status','streamUrl','createdAt'}
print(quote_id)
PY
)"

# Same owner, key, and payload replays the same accepted result.
test "$(curl --silent --show-error \
  --output "${ARTIFACTS}/create-replay.json" \
  --write-out '%{http_code}' \
  --request POST \
  --header 'content-type: application/json' \
  --header 'idempotency-key: quote:test-current-create' \
  --header "x-canonical-internal-token: ${TOKEN}" \
  --header 'x-canonical-subject: owner-api' \
  --data-binary "@${API_DIR}/fixtures/quote-v1/create-request.json" \
  "${BASE_URL}/api/v1/quotes")" = "202"
python3 - "$quote_id" "${ARTIFACTS}/create-replay.json" <<'PY'
import json, sys
assert json.load(open(sys.argv[2]))['quoteId']==sys.argv[1]
PY

# Reusing the same key with a changed payload fails with the public problem shape.
python3 - "$API_DIR/fixtures/quote-v1/create-request.json" \
  "${ARTIFACTS}/create-conflict-request.json" <<'PY'
import json, sys
value=json.load(open(sys.argv[1])); value['employeeCount']=999
json.dump(value, open(sys.argv[2],'w'))
PY
test "$(curl --silent --show-error \
  --output "${ARTIFACTS}/create-conflict.json" \
  --write-out '%{http_code}' \
  --request POST \
  --header 'content-type: application/json' \
  --header 'idempotency-key: quote:test-current-create' \
  --header "x-canonical-internal-token: ${TOKEN}" \
  --header 'x-canonical-subject: owner-api' \
  --data-binary "@${ARTIFACTS}/create-conflict-request.json" \
  "${BASE_URL}/api/v1/quotes")" = "409"
python3 - "${ARTIFACTS}/create-conflict.json" <<'PY'
import json, sys
value=json.load(open(sys.argv[1]))
assert value['code']=='idempotency_key_reused'
assert isinstance(value['message'],str) and value['message']
assert isinstance(value['requestId'],str) and value['requestId']
PY

# The detail surface is public-contract-only and owner scoped.
for _ in $(seq 1 30); do
  status="$(curl --silent --show-error \
    --output "${ARTIFACTS}/detail.json" \
    --write-out '%{http_code}' \
    --header "x-canonical-internal-token: ${TOKEN}" \
    --header 'x-canonical-subject: owner-api' \
    "${BASE_URL}/api/v1/quotes/${quote_id}")"
  [[ "$status" == "200" ]] && break
  sleep 1
done
test "$status" = "200"
python3 - "$quote_id" "${ARTIFACTS}/detail.json" <<'PY'
import json, sys
value=json.load(open(sys.argv[2]))
assert value['quoteId']==sys.argv[1]
assert value['request']['organizationName']=='Example Incorporated'
assert value['eventsUrl']==f"/api/v1/quotes/{sys.argv[1]}/events"
for forbidden in ('owner_subject','persistence','gemini_model','context_record_id','analysis','error_code'):
    assert forbidden not in value
PY

test "$(curl --silent --output /dev/null --write-out '%{http_code}' \
  --header "x-canonical-internal-token: ${TOKEN}" \
  --header 'x-canonical-subject: owner-b' \
  "${BASE_URL}/api/v1/quotes/${quote_id}")" = "404"

# List is paginated-object shaped, not an internal record array.
test "$(curl --silent --show-error \
  --output "${ARTIFACTS}/list.json" \
  --write-out '%{http_code}' \
  --header "x-canonical-internal-token: ${TOKEN}" \
  --header 'x-canonical-subject: owner-api' \
  "${BASE_URL}/api/v1/quotes?limit=25")" = "200"
python3 - "$quote_id" "${ARTIFACTS}/list.json" <<'PY'
import json, sys
value=json.load(open(sys.argv[2]))
assert isinstance(value['quotes'],list) and value['quotes']
assert value['quotes'][0]['quoteId']==sys.argv[1]
assert value['quotes'][0]['organizationName']=='Example Incorporated'
assert set(value).issubset({'quotes','nextCursor'})
PY

# With Gemini intentionally absent, the attempt becomes failed and can be retried.
for _ in $(seq 1 30); do
  curl --silent --fail \
    --header "x-canonical-internal-token: ${TOKEN}" \
    --header 'x-canonical-subject: owner-api' \
    "${BASE_URL}/api/v1/quotes/${quote_id}" \
    >"${ARTIFACTS}/detail-terminal.json"
  terminal="$(python3 - "${ARTIFACTS}/detail-terminal.json" <<'PY'
import json, sys
print(json.load(open(sys.argv[1]))['status'])
PY
)"
  [[ "$terminal" == "failed" ]] && break
  sleep 1
done
test "$terminal" = "failed"

test "$(curl --silent --show-error \
  --output "${ARTIFACTS}/retry.json" \
  --write-out '%{http_code}' \
  --request POST \
  --header 'idempotency-key: quote:test-current-retry' \
  --header "x-canonical-internal-token: ${TOKEN}" \
  --header 'x-canonical-subject: owner-api' \
  "${BASE_URL}/api/v1/quotes/${quote_id}/retry")" = "202"
python3 - "$quote_id" "${ARTIFACTS}/retry.json" <<'PY'
import json, sys
value=json.load(open(sys.argv[2]))
assert value['quoteId']==sys.argv[1]
assert value['status']=='queued'
assert value['streamUrl']==f"/api/v1/quotes/{sys.argv[1]}/events"
assert value['updatedAt'].endswith('Z')
assert set(value)=={'quoteId','status','streamUrl','updatedAt'}
PY

# Operation and event data are durable and append-only.
test "$(psql "$TARGET_ADMIN_URL" -Atqc \
  "SELECT count(*) FROM canonical_cloud__quote.canonical_quote_operation
   WHERE quote_id='${quote_id}'")" = "2"
test "$(psql "$TARGET_ADMIN_URL" -Atqc \
  "SELECT request_json->>'organizationName'
   FROM canonical_cloud__quote.canonical_quote WHERE id='${quote_id}'")" = "Example Incorporated"
test "$(psql "$TARGET_ADMIN_URL" -Atqc \
  "SELECT count(*) FROM canonical_cloud__quote.canonical_quote_event
   WHERE quote_id='${quote_id}' AND created_at IS NOT NULL")" -ge "4"
set +e
psql "$API_URL" -v ON_ERROR_STOP=1 \
  -c "UPDATE canonical_cloud__quote.canonical_quote_operation SET operation='retry'" \
  >/dev/null 2>"${ARTIFACTS}/operation-update.err"
operation_update_status=$?
set -e
test "$operation_update_status" -ne 0
grep -Eqi 'permission denied|no permission' "${ARTIFACTS}/operation-update.err"

# Policy drift fails readiness, is detected by DPM, and repairs without data loss.
psql "$TARGET_ADMIN_URL" -v ON_ERROR_STOP=1 \
  -c "DROP POLICY canonical_quote_operation_owner_policy
      ON canonical_cloud__quote.canonical_quote_operation" >/dev/null
wait_for_status "503" "/readyz"
set +e
"$DPM" diff \
  --source-sql "$API_DIR/db/schema.sql" \
  --target "$MIGRATOR_URL" \
  --shadow "$POSTGRES_ADMIN_URL" \
  --fail-on-diff \
  >"${ARTIFACTS}/policy-drift.sql" 2>"${ARTIFACTS}/policy-drift.err"
drift_status=$?
set -e
test "$drift_status" -eq 2
grep -Eqi 'canonical_quote_operation_owner_policy|CREATE POLICY' \
  "${ARTIFACTS}/policy-drift.sql" "${ARTIFACTS}/policy-drift.err"
"$DPM" apply \
  --source-sql "$API_DIR/db/schema.sql" \
  --target "$MIGRATOR_URL" \
  --shadow "$POSTGRES_ADMIN_URL" \
  --yes >"${ARTIFACTS}/policy-repair.out"
psql "$TARGET_ADMIN_URL" -v ON_ERROR_STOP=1 \
  -f "$API_DIR/db/grants.sql" >/dev/null
wait_for_status "200" "/readyz"
"$DPM" verify \
  --source-sql "$API_DIR/db/schema.sql" \
  --target "$MIGRATOR_URL" \
  --shadow "$POSTGRES_ADMIN_URL" \
  >"${ARTIFACTS}/final-verify.out"
test "$(psql "$TARGET_ADMIN_URL" -Atqc \
  "SELECT count(*) FROM canonical_cloud__quote.canonical_quote_operation
   WHERE quote_id='${quote_id}'")" = "2"

printf 'Canonical current quote-v1 PostgreSQL %s certification passed.\n' "$POSTGRES_MAJOR"
