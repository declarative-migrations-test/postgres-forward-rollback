# AGENTS.md

Keep the production dependency pinned to `declarative-migrations/declarative-postgres-migrate.rs@21eb846e356b2a5aff068b21e77903e6cca50452` unless a reviewed dependency-update pull request advances it. Tests must use throwaway databases, preserve inserted rows across compatible migrations, prove residual drift is non-zero, and never weaken a rollback or convergence assertion merely to make CI green.
