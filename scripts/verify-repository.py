#!/usr/bin/env python3
import json
import re
from pathlib import Path

root = Path(__file__).resolve().parents[1]
manifest = json.loads((root / "bootstrap-manifest.json").read_text())
source = json.loads((root / "canonical-quote-source.json").read_text())
required = [
    "README.md",
    "AGENTS.md",
    "LICENSE",
    ".gitmodules",
    "bootstrap-manifest.json",
    "production-dependency.json",
    "canonical-quote-source.json",
    "scripts/build-dpm.sh",
    "scripts/test-postgres-forward-rollback.sh",
]
missing = [path for path in required if not (root / path).exists()]
if missing:
    raise SystemExit(f"missing required files: {missing}")
expected_dpm = "d05a7880987ddaa271fa88b52c787390ef12b899"
expected_source = "5de04889e23e69b1a0daba48ce62eb7f95ec6194"
if manifest["production_dependency"]["commit"] != expected_dpm:
    raise SystemExit("production dependency pin drifted")
dependency = json.loads((root / "production-dependency.json").read_text())
if dependency["commit"] != expected_dpm:
    raise SystemExit("production dependency ledger drifted")
if source["dpmCommit"] != expected_dpm:
    raise SystemExit("Canonical quote dpm pin drifted")
if source["sourceCommit"] != expected_source:
    raise SystemExit("Canonical quote source pin drifted")
workflow = (root / ".github/workflows/ci.yml").read_text()
for required_text in (
    expected_source,
    "canonical-cloud/canonical-api-server.rs",
    "scripts/test-declarative-postgres.sh",
    "persist-credentials: false",
):
    if required_text not in workflow:
        raise SystemExit(f"workflow omits {required_text}")
for path in root.rglob("*"):
    if not path.is_file() or ".git" in path.parts or path.stat().st_size > 1_000_000:
        continue
    try:
        text = path.read_text()
    except UnicodeDecodeError:
        continue
    if any(marker in text for marker in ("<" * 7, "=" * 7, ">" * 7)):
        raise SystemExit(f"conflict marker in {path}")
    if re.search(r"gh[pousr]_[A-Za-z0-9]{20,}|BEGIN [A-Z ]*PRIVATE KEY", text):
        raise SystemExit(f"credential-shaped content in {path}")
print(f"validated {manifest['organization']}/{manifest['repository']}")
