#!/usr/bin/env bash
set -euo pipefail

DPM="${DPM_BIN:?DPM_BIN is required}"
API_DIR="${CANONICAL_API_DIR:?CANONICAL_API_DIR is required}"
ADMIN="${POSTGRES_ADMIN_URL:-postgres://postgres:quote-test@localhost:5432/postgres}"
PG_MAJOR="${POSTGRES_MAJOR:?POSTGRES_MAJOR is required}"
DB="canonical_quote_v1_pg${PG_MAJOR}"
TARGET="postgres://postgres:quote-test@localhost:5432/${DB}"
RUNTIME="postgres://canonical_api_server:runtime-test@localhost:5432/${DB}"
TMP="${RUNNER_TEMP:-/tmp}"
SERVER_LOG="$TMP/canonical-quote-v1-pg${PG_MAJOR}.log"
SERVER_PID=""
TOKEN="0123456789abcdef0123456789abcdef"
BASE_URL="http://127.0.0.1:18081"
CANONICAL_FIXTURE="$API_DIR/fixtures/quote/v1/request.json"

cleanup() {
  if [[ -n "$SERVER_PID" ]]; then
    kill "$SERVER_PID" >/dev/null 2>&1 || true
    wait "$SERVER_PID" >/dev/null 2>&1 || true
  fi
  psql "$ADMIN" -v ON_ERROR_STOP=1 \
    -c "DROP DATABASE IF EXISTS ${DB} WITH (FORCE)" >/dev/null 2>&1 || true
  psql "$ADMIN" -v ON_ERROR_STOP=1 \
    -c "DROP ROLE IF EXISTS canonical_api_server" >/dev/null 2>&1 || true
}
trap cleanup EXIT
cleanup

test -f "$CANONICAL_FIXTURE"
test "$(git -C "$API_DIR" hash-object fixtures/quote/v1/request.json)" = \
  "fe8bf1ad08a7152d44ead22ee0d082842d28b208"

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
psql "$TARGET" -v ON_ERROR_STOP=1 \
  -f "$API_DIR/db/runtime-grants.sql" >/dev/null

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

# Seed a canonical wire-format row and all child-table relationships directly
# through the restricted runtime identity.
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
  '{
    "organizationName":"Owner A",
    "contactName":"Owner A",
    "contactEmail":"owner-a@example.test",
    "website":"https://example.test",
    "employeeCount":42,
    "annualRevenueBand":"10m_50m",
    "frameworks":["soc2_type_2"],
    "currentStage":"readiness",
    "infrastructure":["aws"],
    "dataSensitivity":["confidential"],
    "targetDate":"2026-12-31",
    "hasSecurityProgram":true,
    "hasPolicies":true,
    "hasRiskAssessment":false,
    "hasIncidentResponsePlan":true,
    "hasVendorManagement":false,
    "notes":"Direct persistence fixture",
    "contextKey":"quote-analysis",
    "answersVersion":1
  }'::jsonb,
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
  if curl --silent --fail "$BASE_URL/readyz" >"$TMP/ready.json"; then
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

# The canonical route must reject unauthenticated, legacy-private, and
# caller-selected context shapes before accepting the exact golden fixture.
test "$(curl --silent --output /dev/null --write-out '%{http_code}' \
  --request POST \
  --header 'content-type: application/json' \
  --data-binary "@$CANONICAL_FIXTURE" \
  "$BASE_URL/api/v1/quotes")" = "401"

cat >"$TMP/legacy-private-request.json" <<'JSON'
{
  "frameworks": ["soc2", "hipaa"],
  "organization": {
    "employee_count": 42,
    "industry": "Software",
    "legal_name": "Legacy API Owner"
  },
  "target_date": "2027-01-15"
}
JSON

test "$(curl --silent --output /dev/null --write-out '%{http_code}' \
  --request POST \
  --header 'content-type: application/json' \
  --header "x-canonical-internal-token: ${TOKEN}" \
  --header 'x-canonical-subject: owner-api' \
  --data-binary "@$TMP/legacy-private-request.json" \
  "$BASE_URL/api/v1/quotes")" = "400"

python3 - "$CANONICAL_FIXTURE" "$TMP/tampered-request.json" <<'PY'
import json
import pathlib
import sys

source = pathlib.Path(sys.argv[1])
target = pathlib.Path(sys.argv[2])
value = json.loads(source.read_text())
value['markdown_context'] = 'caller-selected context must be rejected'
target.write_text(json.dumps(value, separators=(',', ':')))
PY

test "$(curl --silent --output /dev/null --write-out '%{http_code}' \
  --request POST \
  --header 'content-type: application/json' \
  --header "x-canonical-internal-token: ${TOKEN}" \
  --header 'x-canonical-subject: owner-api' \
  --data-binary "@$TMP/tampered-request.json" \
  "$BASE_URL/api/v1/quotes")" = "400"

create_status="$(curl --silent --show-error \
  --output "$TMP/quote-create.json" \
  --write-out '%{http_code}' \
  --request POST \
  --header 'content-type: application/json' \
  --header "x-canonical-internal-token: ${TOKEN}" \
  --header 'x-canonical-subject: owner-api' \
  --data-binary "@$CANONICAL_FIXTURE" \
  "$BASE_URL/api/v1/quotes")"
test "$create_status" = "202"

quote_id="$(python3 - "$TMP/quote-create.json" <<'PY'
import datetime
import json
import pathlib
import sys
import uuid

value = json.loads(pathlib.Path(sys.argv[1]).read_text())
quote_id = value['quoteId']
uuid.UUID(quote_id)
assert value['status'] == 'queued'
assert value['streamUrl'] == f'/api/v1/quotes/{quote_id}/events'
created_at = value['createdAt']
parsed = datetime.datetime.fromisoformat(created_at.replace('Z', '+00:00'))
assert parsed.tzinfo is not None
assert set(value) == {'quoteId', 'status', 'streamUrl', 'createdAt'}
print(quote_id)
PY
)"

for _ in $(seq 1 30); do
  read_status="$(curl --silent --show-error \
    --output "$TMP/quote-read.json" \
    --write-out '%{http_code}' \
    --header "x-canonical-internal-token: ${TOKEN}" \
    --header 'x-canonical-subject: owner-api' \
    "$BASE_URL/api/v1/quotes/${quote_id}")"
  if [[ "$read_status" == "200" ]]; then
    break
  fi
  sleep 1
done
test "$read_status" = "200"
python3 - "$TMP/quote-read.json" <<'PY'
import json
import pathlib
import sys

value = json.loads(pathlib.Path(sys.argv[1]).read_text())
assert value['persistence'] == 'postgres'
assert value['organization_name'] == 'Example Company'
assert value['frameworks'] == [
    'soc2_type_2',
    'nist_csf_2',
    'nist_800_53',
    'hipaa',
]
PY

test "$(curl --silent --output /dev/null --write-out '%{http_code}' \
  --header "x-canonical-internal-token: ${TOKEN}" \
  --header 'x-canonical-subject: owner-b' \
  "$BASE_URL/api/v1/quotes/${quote_id}")" = "404"

list_status="$(curl --silent --show-error \
  --output "$TMP/quote-list.json" \
  --write-out '%{http_code}' \
  --header "x-canonical-internal-token: ${TOKEN}" \
  --header 'x-canonical-subject: owner-api' \
  "$BASE_URL/api/v1/quotes")"
test "$list_status" = "200"
python3 - "$TMP/quote-list.json" "$quote_id" <<'PY'
import json
import pathlib
import sys

quotes = json.loads(pathlib.Path(sys.argv[1]).read_text())
assert len(quotes) == 1
assert quotes[0]['quote_id'] == sys.argv[2]
assert quotes[0]['organization_name'] == 'Example Company'
assert quotes[0]['persistence'] == 'postgres'
PY

# Prove the persisted wire request is canonical and the selected context remains
# server-owned.
test "$(psql "$TARGET" -Atqc "SELECT request_json->>'organizationName' FROM canonical_quote WHERE id='${quote_id}'")" = "Example Company"
test "$(psql "$TARGET" -Atqc "SELECT request_json->>'answersVersion' FROM canonical_quote WHERE id='${quote_id}'")" = "1"
test "$(psql "$TARGET" -Atqc "SELECT request_json ? 'organization' FROM canonical_quote WHERE id='${quote_id}'")" = "f"
test "$(psql "$TARGET" -Atqc "SELECT request_json ? 'markdown_context' FROM canonical_quote WHERE id='${quote_id}'")" = "f"
test "$(psql "$TARGET" -Atqc "SELECT context_record_id = '55555555-5555-4555-8555-555555555555'::uuid FROM canonical_quote WHERE id='${quote_id}'")" = "t"
test "$(psql "$TARGET" -Atqc "SELECT application_context_markdown <> '' FROM canonical_quote WHERE id='${quote_id}'")" = "t"

# Prove readiness is schema-aware and DPM detects and repairs policy drift
# without losing canonical quote data.
psql "$TARGET" -v ON_ERROR_STOP=1 \
  -c "DROP POLICY canonical_quote_owner_policy ON canonical_quote" >/dev/null

test "$(curl --silent --output /dev/null --write-out '%{http_code}' "$BASE_URL/readyz")" = "503"
if "$DPM" diff \
  --source-sql "$API_DIR/db/schema.sql" \
  --target "$TARGET" \
  --shadow "$ADMIN" \
  --fail-on-diff \
  >"$TMP/canonical-quote-v1-drift.sql" 2>&1
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
test "$(psql "$TARGET" -Atqc "SELECT request_json->>'organizationName' FROM canonical_quote WHERE id='${quote_id}'")" = "Example Company"
printf 'Canonical quote v1 PostgreSQL %s certification passed.\n' "$PG_MAJOR"
