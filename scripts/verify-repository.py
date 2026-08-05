#!/usr/bin/env python3
import json
import re
from pathlib import Path

root = Path(__file__).resolve().parents[1]
dependency = json.loads((root / "production-dependency.json").read_text())
assert dependency["commit"] == "21eb846e356b2a5aff068b21e77903e6cca50452"
for required in ["fixtures/v1.sql", "fixtures/v2.sql", "scripts/build-dpm.sh", "scripts/test-postgres-rollback.sh", ".github/workflows/ci.yml"]:
    assert (root / required).is_file(), required
for path in root.rglob("*"):
    if not path.is_file() or ".git" in path.parts or path.stat().st_size > 1_000_000:
        continue
    text = path.read_text(errors="ignore")
    assert not any(marker in text for marker in ("<" * 7, "=" * 7, ">" * 7)), path
    assert not re.search(r"gh[pousr]_[A-Za-z0-9]{20,}", text), path
print("repository contract validated")
