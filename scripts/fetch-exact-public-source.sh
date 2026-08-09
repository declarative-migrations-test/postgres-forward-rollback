#!/usr/bin/env bash
set -euo pipefail

repository="${1:?repository in owner/name form is required}"
commit="${2:?exact 40-character commit SHA is required}"
destination="${3:?destination directory is required}"

if [[ ! "$repository" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
  echo "invalid repository: $repository" >&2
  exit 64
fi
if [[ ! "$commit" =~ ^[0-9a-f]{40}$ ]]; then
  echo "invalid exact commit SHA: $commit" >&2
  exit 64
fi

rm -rf "$destination"
git init --quiet "$destination"
git -C "$destination" remote add origin "https://github.com/${repository}.git"
git -C "$destination" -c protocol.version=2 fetch \
  --quiet \
  --no-tags \
  --depth=1 \
  origin "$commit"
git -C "$destination" checkout --quiet --detach FETCH_HEAD
observed="$(git -C "$destination" rev-parse HEAD)"
if [[ "$observed" != "$commit" ]]; then
  echo "exact-source mismatch: expected $commit, observed $observed" >&2
  exit 1
fi
git -C "$destination" remote remove origin
printf 'fetched %s at exact commit %s\n' "$repository" "$commit"
