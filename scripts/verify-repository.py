#!/usr/bin/env python3
import json
import re
from pathlib import Path

root = Path(__file__).resolve().parents[1]
manifest = json.loads((root / "bootstrap-manifest.json").read_text())
required = [
    "README.md",
    "AGENTS.md",
    "LICENSE",
    ".gitmodules",
    "bootstrap-manifest.json",
    "scripts/build-dpm.sh",
]
missing = [path for path in required if not (root / path).exists()]
if missing:
    raise SystemExit(f"missing required files: {missing}")
if manifest["production_dependency"]["commit"] != "21eb846e356b2a5aff068b21e77903e6cca50452":
    raise SystemExit("production dependency pin drifted")

# The vendored production dependency is independently pinned by Git SHA. Scan
# only this harness's owned files so upstream documentation examples cannot be
# misclassified as unresolved merge markers or credentials.
for path in root.rglob("*"):
    relative = path.relative_to(root)
    if (
        not path.is_file()
        or ".git" in relative.parts
        or "vendor" in relative.parts
        or path.stat().st_size > 1_000_000
    ):
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
