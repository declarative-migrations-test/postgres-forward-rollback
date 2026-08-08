# postgres-forward-rollback

Repeated forward, rollback, and recovery certification against live PostgreSQL with schema convergence and data-preservation assertions.

This repository is part of the isolated `declarative-migrations-test` certification fleet. It pins the production implementation as a Git submodule at `declarative-migrations/declarative-postgres-migrate.rs@d05a7880987ddaa271fa88b52c787390ef12b899` and exercises real PostgreSQL instances in GitHub Actions.

## Canonical quote certification

The Canonical quote lane pins `canonical-cloud/canonical-api-server.rs@26967bed96b1b48ea846c3fd418018ea40f4b9e1` and verifies the exact `canonical_cloud__quote` desired state and schema digest.

The lifecycle lane proves declarative apply/replay, forced RLS, owner isolation, explicit grants, drift reporting, destructive-change gating, and row preservation on PostgreSQL 17.

The backup/restore lane adds an operational recovery proof:

1. apply the reviewed schema to PostgreSQL 17 through the dedicated migrator role;
2. seed synthetic owner-scoped context, quote, event, and model-attempt rows through the API runtime role;
3. create a custom-format, schema-scoped dump without owners or ACLs;
4. restore it into PostgreSQL 18 under the migrator identity;
5. reconcile reviewed grants;
6. require an empty `dpm diff` and successful shadow replay;
7. re-certify object ownership, forced RLS, policies, API/web capability separation, row hashes, restored triggers, and restored sequence progression.

No production database URL, customer record, Cloudflare token, Supabase key, Gemini key, Kubernetes secret, or R2 credential enters these workflows.

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

The backup/restore script additionally requires disposable PostgreSQL 17 and 18 listeners and Docker for engine-matched `pg_dump`/`pg_restore` clients.

Every behavior change must add a regression, preserve exact dependency pinning, avoid credentials in source or logs, and land through a pull request.
