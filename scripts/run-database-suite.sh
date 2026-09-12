#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
command -v docker >/dev/null || { echo "blocked: docker unavailable"; exit 78; }
cd "$root"; docker compose up -d --wait; trap 'docker compose down -v' EXIT
./scripts/bootstrap-upstream.sh git-submodule
: "${MIGRATION_TEST_COMMAND:?set apply/rollback command}"
bash -lc "$MIGRATION_TEST_COMMAND"
