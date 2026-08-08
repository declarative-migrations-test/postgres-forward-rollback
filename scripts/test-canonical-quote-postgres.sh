#!/usr/bin/env bash
set -euo pipefail

DPM="${DPM_BIN:?DPM_BIN is required}"
ADMIN="${POSTGRES_ADMIN_URL:-postgres://postgres:postgres@localhost:5432/postgres}"
DB="dm_canonical_quote_readiness"
TARGET="postgres://postgres:postgres@localhost:5432/${DB}"
ROLE="canonical_quote_runtime_ci"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
schema="$root/fixtures/canonical-quote-v1.sql"
provenance="$root/fixtures/canonical-quote-v1.provenance.json"

cleanup() {
  psql "$ADMIN" -v ON_ERROR_STOP=1 -c "DROP DATABASE IF EXISTS ${DB} WITH (FORCE)" >/dev/null 2>&1 || true
  psql "$ADMIN" -v ON_ERROR_STOP=1 -c "DROP ROLE IF EXISTS ${ROLE}" >/dev/null 2>&1 || true
}
trap cleanup EXIT
cleanup

expected_blob="$(python3 - "$provenance" <<'PY'
import json
import sys
print(json.load(open(sys.argv[1]))["source_git_blob"])
PY
)"
actual_blob="$(git -C "$root" hash-object "${schema#$root/}")"
if [[ "$actual_blob" != "$expected_blob" ]]; then
  echo "Canonical schema fixture drift: expected $expected_blob, observed $actual_blob" >&2
  exit 1
fi

psql "$ADMIN" -v ON_ERROR_STOP=1 -c "CREATE DATABASE ${DB}" >/dev/null

apply_and_verify() {
  "$DPM" apply \
    --source-sql "$schema" \
    --target "$TARGET" \
    --shadow "$ADMIN" \
    --yes
  "$DPM" diff \
    --source-sql "$schema" \
    --target "$TARGET" \
    --shadow "$ADMIN" \
    --fail-on-diff >/dev/null
  "$DPM" verify \
    --source-sql "$schema" \
    --target "$TARGET" \
    --shadow "$ADMIN"
}

assert_scalar() {
  local expected="$1"
  local query="$2"
  local observed
  observed="$(psql "$TARGET" -Atq -v ON_ERROR_STOP=1 -c "$query")"
  if [[ "$observed" != "$expected" ]]; then
    echo "PostgreSQL readiness assertion failed" >&2
    echo "query: $query" >&2
    echo "expected: $expected" >&2
    echo "observed: $observed" >&2
    exit 1
  fi
}

apply_and_verify

assert_scalar 4 "SELECT count(*) FROM pg_class WHERE relkind='r' AND relname IN ('canonical_context','canonical_quote','canonical_quote_event','canonical_model_attempt')"
assert_scalar 4 "SELECT count(*) FROM pg_class WHERE relkind='r' AND relrowsecurity AND relforcerowsecurity AND relname IN ('canonical_context','canonical_quote','canonical_quote_event','canonical_model_attempt')"
assert_scalar 4 "SELECT count(*) FROM pg_policies WHERE schemaname='public' AND tablename IN ('canonical_context','canonical_quote','canonical_quote_event','canonical_model_attempt')"
assert_scalar 5 "SELECT count(*) FROM pg_indexes WHERE schemaname='public' AND indexname IN ('canonical_context_owner_active_idx','canonical_context_one_active_per_owner_idx','canonical_quote_owner_created_idx','canonical_quote_event_quote_sequence_idx','canonical_model_attempt_quote_started_idx')"
assert_scalar 1 "SELECT count(*) FROM pg_index i JOIN pg_class c ON c.oid=i.indexrelid WHERE c.relname='canonical_context_one_active_per_owner_idx' AND i.indisunique AND position('active' in lower(pg_get_expr(i.indpred,i.indrelid))) > 0"
assert_scalar 2 "SELECT count(*) FROM pg_trigger WHERE NOT tgisinternal AND tgname IN ('canonical_context_set_updated_at','canonical_quote_set_updated_at')"
assert_scalar 1 "SELECT count(*) FROM pg_proc WHERE proname='canonical_set_updated_at'"

psql "$ADMIN" -v ON_ERROR_STOP=1 >/dev/null <<SQL
CREATE ROLE ${ROLE} NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOBYPASSRLS;
SQL

psql "$TARGET" -v ON_ERROR_STOP=1 >/dev/null <<SQL
GRANT CONNECT ON DATABASE ${DB} TO ${ROLE};
GRANT USAGE ON SCHEMA public TO ${ROLE};
GRANT SELECT, INSERT, UPDATE ON canonical_context TO ${ROLE};
GRANT SELECT, INSERT, UPDATE ON canonical_quote TO ${ROLE};
GRANT SELECT, INSERT ON canonical_quote_event TO ${ROLE};
GRANT SELECT, INSERT, UPDATE ON canonical_model_attempt TO ${ROLE};
GRANT USAGE, SELECT ON SEQUENCE canonical_quote_event_sequence_id_seq TO ${ROLE};
SQL

role_flags="$(psql "$ADMIN" -Atq -v ON_ERROR_STOP=1 -c "SELECT rolsuper::int || ':' || rolcreatedb::int || ':' || rolcreaterole::int || ':' || rolbypassrls::int FROM pg_roles WHERE rolname='${ROLE}'")"
if [[ "$role_flags" != "0:0:0:0" ]]; then
  echo "runtime role has elevated privileges: $role_flags" >&2
  exit 1
fi

psql "$TARGET" -v ON_ERROR_STOP=1 >/dev/null <<'SQL'
BEGIN;
SELECT set_config('app.current_subject', 'owner-a', true);
INSERT INTO canonical_context (
    id,
    owner_subject,
    name,
    context_markdown,
    context_json,
    active
) VALUES (
    '10000000-0000-4000-8000-000000000001',
    'owner-a',
    'Canonical quote readiness',
    'Synthetic test context only.',
    '{"environment":"test","contains_secrets":false}'::jsonb,
    TRUE
);
INSERT INTO canonical_context (
    id,
    owner_subject,
    name,
    context_markdown,
    context_json,
    active
) VALUES (
    '10000000-0000-4000-8000-000000000005',
    'owner-a',
    'Historical inactive context',
    'Synthetic inactive context only.',
    '{"environment":"test","active":false}'::jsonb,
    FALSE
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
    '20000000-0000-4000-8000-000000000002',
    'owner-a',
    '10000000-0000-4000-8000-000000000001',
    '{"organizationName":"Example Company","contactName":"Taylor Example","contactEmail":"security@example.com","employeeCount":120,"frameworks":["soc2_type_2","nist_800_53","hipaa"],"currentStage":"readiness","infrastructure":["aws","saas_only"],"dataSensitivity":["confidential","pii","phi"],"hasSecurityProgram":true,"hasPolicies":true,"hasRiskAssessment":false,"hasIncidentResponsePlan":true,"hasVendorManagement":false,"answersVersion":1}'::jsonb,
    'Synthetic application policy.',
    'Synthetic test context only.',
    '{"environment":"test","contains_secrets":false}'::jsonb,
    'gemini-3.6-pro',
    'queued'
);
INSERT INTO canonical_quote_event (
    quote_id,
    owner_subject,
    status,
    details_json
) VALUES (
    '20000000-0000-4000-8000-000000000002',
    'owner-a',
    'queued',
    '{"analysis_available":false}'::jsonb
);
INSERT INTO canonical_model_attempt (
    id,
    quote_id,
    owner_subject,
    provider,
    model,
    status
) VALUES (
    '30000000-0000-4000-8000-000000000003',
    '20000000-0000-4000-8000-000000000002',
    'owner-a',
    'google-gemini',
    'gemini-3.6-pro',
    'started'
);
COMMIT;
SQL

if psql "$TARGET" -v ON_ERROR_STOP=1 >/dev/null 2>&1 <<'SQL'
INSERT INTO canonical_context (
    id,
    owner_subject,
    name,
    context_markdown,
    context_json,
    active
) VALUES (
    '10000000-0000-4000-8000-000000000006',
    'owner-a',
    'Conflicting active context',
    '',
    '{}'::jsonb,
    TRUE
);
SQL
then
  echo "partial unique index accepted a second active context for one owner" >&2
  exit 1
fi

for _cycle in 1 2 3; do
  apply_and_verify
  assert_scalar 2 "SELECT count(*) FROM canonical_context WHERE owner_subject='owner-a'"
  assert_scalar 1 "SELECT count(*) FROM canonical_context WHERE owner_subject='owner-a' AND active"
  assert_scalar 1 "SELECT count(*) FROM canonical_quote WHERE id='20000000-0000-4000-8000-000000000002'"
  assert_scalar 1 "SELECT count(*) FROM canonical_quote_event WHERE quote_id='20000000-0000-4000-8000-000000000002'"
  assert_scalar 1 "SELECT count(*) FROM canonical_model_attempt WHERE id='30000000-0000-4000-8000-000000000003'"
done

query_as_subject() {
  local subject="$1"
  psql "$TARGET" -Atq -v ON_ERROR_STOP=1 <<SQL | grep -E '^[0-9]+$' | tail -n 1
BEGIN;
SET LOCAL ROLE ${ROLE};
WITH configured AS (
  SELECT set_config('app.current_subject', '${subject}', true)
)
SELECT count(*) FROM canonical_quote, configured;
ROLLBACK;
SQL
}

if [[ "$(query_as_subject owner-a)" != "1" ]]; then
  echo "owner-a could not read its quote through forced RLS" >&2
  exit 1
fi
if [[ "$(query_as_subject owner-b)" != "0" ]]; then
  echo "owner-b could read another owner's quote" >&2
  exit 1
fi

if psql "$TARGET" -v ON_ERROR_STOP=1 >/dev/null 2>&1 <<SQL
BEGIN;
SET LOCAL ROLE ${ROLE};
SELECT set_config('app.current_subject', 'owner-b', true);
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
    '40000000-0000-4000-8000-000000000004',
    'owner-a',
    '10000000-0000-4000-8000-000000000001',
    '{}'::jsonb,
    '',
    '',
    '{}'::jsonb,
    'gemini-3.6-pro',
    'queued'
);
ROLLBACK;
SQL
then
  echo "forced RLS accepted a forged owner_subject" >&2
  exit 1
fi

psql "$TARGET" -v ON_ERROR_STOP=1 -c "DROP INDEX canonical_quote_owner_created_idx" >/dev/null
if "$DPM" diff \
  --source-sql "$schema" \
  --target "$TARGET" \
  --shadow "$ADMIN" \
  --fail-on-diff >/dev/null 2>&1
then
  echo "schema drift was not detected after dropping a required index" >&2
  exit 1
fi
apply_and_verify
assert_scalar 1 "SELECT count(*) FROM pg_indexes WHERE schemaname='public' AND indexname='canonical_quote_owner_created_idx'"

assert_scalar 1 "SELECT count(*) FROM canonical_quote WHERE request_json->>'organizationName'='Example Company' AND request_json->'frameworks' ? 'nist_800_53' AND gemini_model='gemini-3.6-pro'"

echo "Canonical quote PostgreSQL readiness certification passed"
