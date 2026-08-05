# postgres-forward-rollback

Repeated forward and destructive rollback certification against live PostgreSQL with schema convergence and data-preservation assertions.

This repository is part of the isolated `declarative-migrations-test` certification fleet. It pins the production implementation as a Git submodule at `declarative-migrations/declarative-postgres-migrate.rs@21eb846e356b2a5aff068b21e77903e6cca50452` and exercises real PostgreSQL and/or CockroachDB instances in GitHub Actions.

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
