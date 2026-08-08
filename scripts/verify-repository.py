#!/usr/bin/env python3
import json
import re
import subprocess
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

expected_dependency = "21eb846e356b2a5aff068b21e77903e6cca50452"
if manifest["production_dependency"]["commit"] != expected_dependency:
    raise SystemExit("production dependency pin drifted")

index = subprocess.check_output(
    ["git", "-C", str(root), "ls-files", "--stage", "-z"],
    text=False,
)
tracked_files: list[Path] = []
for entry in index.split(b"\0"):
    if not entry:
        continue
    metadata, raw_path = entry.split(b"\t", 1)
    mode, object_id, stage = metadata.decode("ascii").split()
    path = Path(raw_path.decode("utf-8"))
    if mode == "160000":
        if path.as_posix() == "vendor/declarative-postgres-migrate.rs" and object_id != expected_dependency:
            raise SystemExit(
                f"production dependency gitlink drifted: expected {expected_dependency}, observed {object_id}"
            )
        continue
    if stage != "0":
        raise SystemExit(f"unmerged index entry for {path}")
    tracked_files.append(root / path)

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
    f"validated {manifest['organization']}/{manifest['repository']} "
    f"with {len(tracked_files)} tracked non-submodule files"
)
