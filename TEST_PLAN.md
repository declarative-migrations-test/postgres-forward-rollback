# Test plan

- Verify repeated apply and rollback with schema/data equivalence on PostgreSQL across the supported happy-path states and canonical fixtures.
- Verify repeated apply and rollback with schema/data equivalence on PostgreSQL under retries, interruption, concurrency, offline operation, or partial failure.
- Verify repeated apply and rollback with schema/data equivalence on PostgreSQL preserves authorization, idempotency, integrity, observability, and actionable failure classification.

## Classification

- product regression
- blocked dependency
- harness regression
