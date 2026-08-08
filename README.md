# postgres-forward-rollback

Repeated forward and destructive rollback certification against live PostgreSQL with schema convergence and data-preservation assertions.

This repository is part of the isolated `declarative-migrations-test` certification fleet. It pins the production implementation as a Git submodule at `declarative-migrations/declarative-postgres-migrate.rs@21eb846e356b2a5aff068b21e77903e6cca50452` and exercises real PostgreSQL instances in GitHub Actions.

## Canonical quote readiness

The `fixtures/canonical-quote-v1.sql` scenario is a byte-identical snapshot of `canonical-cloud/canonical-api-server.rs@849b0b161860739e6b9f219a52adff6c42193bc8:db/schema.sql`. Its provenance file records the source Git blob and the exact declarative migrator revision.

The isolated PostgreSQL 17 test proves:

- declarative apply, zero-diff, and verify convergence;
- three idempotent replays without losing seeded context, quote, event, or model-attempt rows;
- all four quote tables have enabled and forced row-level security;
- the four owner policies, four required indexes, two update triggers, and trigger function exist;
- a non-owner, non-superuser, non-`BYPASSRLS` runtime role can read only its selected subject;
- a forged `owner_subject` insert is rejected;
- intentional index drift is detected and repaired;
- the stored request retains the canonical camelCase quote contract and `nist_800_53` framework value.

All data and identifiers are synthetic. The workflow has no production database, Cloudflare, Supabase, R2, Kubernetes, or secret-store access.

## Fleet

- `.github`
- `postgres-forward-rollback`
- `cockroach-forward-rollback`
- `cross-engine-compatibility`
- `concurrent-migrator-lock`
- `failure-injection-atomicity`
- `schema-drift-detection`
- `cli-mcp-contract`

## Local contract

```bash
git submodule update --init --recursive
scripts/build-dpm.sh
```

Every behavior change must add a regression, preserve exact dependency pinning, avoid credentials in source or logs, and land through a pull request.
