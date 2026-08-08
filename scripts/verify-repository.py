#!/usr/bin/env python3
import json
import re
import subprocess
from pathlib import Path

root = Path(__file__).resolve().parents[1]
manifest = json.loads((root / "bootstrap-manifest.json").read_text())
dependency = json.loads((root / "production-dependency.json").read_text())
source = json.loads((root / "canonical-quote-source.json").read_text())

required = [
    "README.md",
    "AGENTS.md",
    "LICENSE",
    ".gitmodules",
    "bootstrap-manifest.json",
    "production-dependency.json",
    "canonical-quote-source.json",
    ".github/workflows/ci.yml",
    ".github/workflows/canonical-quote-readiness.yml",
    "scripts/build-dpm.sh",
    "scripts/test-postgres-forward-rollback.sh",
    "scripts/test-canonical-quote-readiness.sh",
]
missing = [path for path in required if not (root / path).exists()]
if missing:
    raise SystemExit(f"missing required files: {missing}")

expected_dpm = "d05a7880987ddaa271fa88b52c787390ef12b899"
if manifest["production_dependency"]["commit"] != expected_dpm:
    raise SystemExit("production dependency pin drifted")
if dependency.get("repository") != "declarative-migrations/declarative-postgres-migrate.rs":
    raise SystemExit("production dependency repository drifted")
if dependency.get("commit") != expected_dpm:
    raise SystemExit("production dependency ledger drifted")

expected_source_keys = {
    "schemaVersion",
    "sourceRepository",
    "sourceCommit",
    "schemaPath",
    "schemaSha256",
    "testScript",
    "dpmRepository",
    "dpmCommit",
}
if set(source) != expected_source_keys:
    raise SystemExit("Canonical quote source manifest fields drifted")
if source["schemaVersion"] != 1:
    raise SystemExit("Canonical quote source manifest version drifted")
if source["sourceRepository"] != "canonical-cloud/canonical-api-server.rs":
    raise SystemExit("Canonical quote source repository drifted")
if not re.fullmatch(r"[0-9a-f]{40}", source["sourceCommit"]):
    raise SystemExit("Canonical quote source commit is not an exact SHA")
if source["schemaPath"] != "db/schema.sql":
    raise SystemExit("Canonical quote schema path drifted")
if not re.fullmatch(r"[0-9a-f]{64}", source["schemaSha256"]):
    raise SystemExit("Canonical quote schema digest is invalid")
if source["testScript"] != "scripts/test-declarative-postgres.sh":
    raise SystemExit("Canonical quote certification script drifted")
if source["dpmRepository"] != dependency["repository"]:
    raise SystemExit("Canonical quote dpm repository drifted")
if source["dpmCommit"] != expected_dpm:
    raise SystemExit("Canonical quote dpm pin drifted")

index = subprocess.check_output(
    ["git", "-C", str(root), "ls-files", "--stage", "-z"],
    text=False,
)
tracked_files: list[Path] = []
observed_gitlink = None
for entry in index.split(b"\0"):
    if not entry:
        continue
    metadata, raw_path = entry.split(b"\t", 1)
    mode, object_id, stage = metadata.decode("ascii").split()
    path = Path(raw_path.decode("utf-8"))
    if stage != "0":
        raise SystemExit(f"unmerged index entry for {path}")
    if mode == "160000":
        if path.as_posix() == "vendor/declarative-postgres-migrate.rs":
            observed_gitlink = object_id
        continue
    tracked_files.append(root / path)
if observed_gitlink != expected_dpm:
    raise SystemExit(
        f"production dependency gitlink drifted: expected {expected_dpm}, "
        f"observed {observed_gitlink}"
    )

workflow = (root / ".github/workflows/ci.yml").read_text()
for required_text in (
    f"repository: {source['sourceRepository']}",
    f"ref: {source['sourceCommit']}",
    source["testScript"],
    "persist-credentials: false",
):
    if required_text not in workflow:
        raise SystemExit(f"workflow omits {required_text}")

readiness_workflow = (
    root / ".github/workflows/canonical-quote-readiness.yml"
).read_text()
for required_text in (
    f"repository: {source['sourceRepository']}",
    f"ref: {source['sourceCommit']}",
    "scripts/test-canonical-quote-readiness.sh",
    "postgres: ['17', '18']",
    "cargo test --locked --all-targets",
    "cargo clippy --locked --all-targets",
    "persist-credentials: false",
):
    if required_text not in readiness_workflow:
        raise SystemExit(f"readiness workflow omits {required_text}")

readiness_script = (
    root / "scripts/test-canonical-quote-readiness.sh"
).read_text()
for required_text in (
    "/readyz",
    "canonical_cloud__quote__api_rw",
    "canonical_cloud__quote__migrator",
    "cross-owner-event",
    "cross-owner-model",
    "BYPASSRLS",
    "DROP POLICY canonical_quote_owner_policy",
    "--fail-on-diff",
):
    if required_text not in readiness_script:
        raise SystemExit(f"readiness script omits {required_text}")

credential = re.compile(r"gh[pousr]_[A-Za-z0-9]{20,}|BEGIN [A-Z ]*PRIVATE KEY")
for path in tracked_files:
    if not path.is_file() or path.stat().st_size > 1_000_000:
        continue
    try:
        text = path.read_text()
    except UnicodeDecodeError:
        continue
    if any(marker in text for marker in ("<" * 7, "=" * 7, ">" * 7)):
        raise SystemExit(f"conflict marker in {path.relative_to(root)}")
    if credential.search(text):
        raise SystemExit(f"credential-shaped content in {path.relative_to(root)}")

print(
    f"validated {manifest['organization']}/{manifest['repository']} at "
    f"Canonical source {source['sourceCommit']}"
)
