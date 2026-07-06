"""License gate: fail CI if any dependency carries a non-permissive license.

Usage: python scripts/check_licenses.py licenses.json
where licenses.json is the output of pip-licenses --format=json.
Policy: ADR 0010 / BUILD_SPEC §10.6.
"""

from __future__ import annotations

import json
import sys

FORBIDDEN = (
    "AGPL",
    "GPL",  # catches GPL and LGPL
    "CC-BY-NC",
    "CC BY-NC",
    "CC-BY-ND",
    "CC BY-ND",
    "Commons Clause",
    "SSPL",
)

# Documented exceptions (name -> rationale). Keep in sync with docs/licenses.md.
ALLOWED_EXCEPTIONS: dict[str, str] = {
    # Mandatory transitive dep of spec-pinned librosa. LGPL-2.1 dynamically
    # linked/relinkable (the policy excludes LGPL-static only). See docs/licenses.md.
    "soxr": "LGPL-2.1 dynamic; librosa hard dependency",
}


def main(path: str) -> int:
    with open(path, encoding="utf-8") as f:
        entries = json.load(f)
    bad: list[str] = []
    for entry in entries:
        name = entry["Name"]
        license_str = entry.get("License", "")
        if name in ALLOWED_EXCEPTIONS:
            continue
        # Dual licenses like "Apache-2.0 OR GPL-2.0" are fine if a permissive option exists.
        options = [part.strip() for part in license_str.replace(";", " OR ").split(" OR ")]
        if all(any(tok in opt.upper() for tok in FORBIDDEN) for opt in options):
            bad.append(f"{name}: {license_str}")
    if bad:
        print("FORBIDDEN LICENSES FOUND:")
        print("\n".join(f"  {line}" for line in bad))
        return 1
    print(f"License gate OK ({len(entries)} packages checked).")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
