# PostgreSQL rollback end-to-end certification

This repository continuously certifies `declarative-migrations/declarative-postgres-migrate.rs` against live PostgreSQL instances.

The workflow pins production commit `21eb846e356b2a5aff068b21e77903e6cca50452`, builds the real `dpm` CLI, and runs repeated forward, gated-rollback, destructive-rollback, idempotency, convergence, and data-preservation checks on PostgreSQL 16 and 17.

## Local run

```bash
export POSTGRES_ADMIN_URL=postgres://postgres@localhost:5432/postgres
scripts/build-dpm.sh
DPM_BIN="$PWD/vendor/dpm/target/release/dpm" scripts/test-postgres-rollback.sh
```

The test owns a throwaway database and removes it on exit. Never point it at a persistent database.
