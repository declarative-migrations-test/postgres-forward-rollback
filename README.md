# postgres-forward-rollback

    Independent **database conformance** harness in `declarative-migrations-test` for `declarative-migrations`.

    **Readiness:** `ready`  
    **Primary dependency strategy:** `matrix`  
    **Scheduled cadence:** `23 4 * * 2,5` UTC  
    **Live infrastructure:** PostgreSQL

    ## Upstream repositories

    - `declarative-migrations/declarative-postgres-migrate.rs`

    ## Acceptance objectives

    1. Verify repeated apply and rollback with schema/data equivalence on PostgreSQL across the supported happy-path states and canonical fixtures.
2. Verify repeated apply and rollback with schema/data equivalence on PostgreSQL under retries, interruption, concurrency, offline operation, or partial failure.
3. Verify repeated apply and rollback with schema/data equivalence on PostgreSQL preserves authorization, idempotency, integrity, observability, and actionable failure classification.

    ## Dependency paths

    This repository tests the upstream through independent installation paths:

    1. `./scripts/bootstrap-upstream.sh git-submodule`
    2. `./scripts/bootstrap-upstream.sh zed`
    3. `./scripts/bootstrap-upstream.sh native-package`

    The publisher materializes a real Git submodule when authenticated access is available. Zed and native package coordinates are recorded in `dependency-contract.yaml`; missing unpublished packages are reported as blocked readiness rather than silently skipped.

    ## Check tiers

    ```bash
    python3 -m pip install -e '.[test]'
    pytest -q
    ./scripts/readiness.py --offline
    ./scripts/run-live.sh
    ```

    Pull requests validate the harness and deterministic contract fixtures. Secret-, service-, emulator-, desktop-, database-, provider-, chaos-, scale-, and soak-dependent checks run by schedule or manual dispatch.

    A live result must be classified as one of:

    - **product regression** — a behavioral invariant fails after dependencies are ready;
    - **blocked dependency** — an upstream, credential, package, emulator, provider sandbox, or deployment is unavailable;
    - **harness regression** — generated metadata, fixtures, workflow, or runner setup is invalid.

    Managed by `github-test-org-factory/1.0.0`.
