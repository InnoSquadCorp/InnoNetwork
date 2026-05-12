#!/usr/bin/env bash
# Guards public enum cases that are documented as provisionally stable.
#
# Adding or removing a guarded case is allowed, but it must be intentional:
# update API_STABILITY.md, CHANGELOG.md / migration notes as needed, then update
# Scripts/enum-cases/provisional-enum-cases.allowlist in the same change.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
allowlist="$repo_root/Scripts/enum-cases/provisional-enum-cases.allowlist"

python3 - "$repo_root" "$allowlist" <<'PY'
from pathlib import Path
import re
import sys

repo_root = Path(sys.argv[1])
allowlist_path = Path(sys.argv[2])

if not allowlist_path.exists():
    print(f"::error::missing allowlist: {allowlist_path}", file=sys.stderr)
    sys.exit(1)

expected = set()
for raw_line in allowlist_path.read_text().splitlines():
    line = raw_line.strip()
    if not line or line.startswith("#"):
        continue
    expected.add(line)

guarded_enums = {item.rsplit(".", 1)[0] for item in expected}
actual = set()
seen_enums = set()


def split_cases(case_part: str) -> list[str]:
    parts = []
    buffer = []
    paren_depth = 0
    for char in case_part:
        if char == "(":
            paren_depth += 1
        elif char == ")" and paren_depth > 0:
            paren_depth -= 1
        elif char == "," and paren_depth == 0:
            parts.append("".join(buffer).strip())
            buffer = []
            continue
        buffer.append(char)
    if buffer:
        parts.append("".join(buffer).strip())
    return parts


case_name_pattern = re.compile(r"`?([A-Za-z_][A-Za-z0-9_]*)`?")
enum_pattern = re.compile(r"\bpublic\s+enum\s+([A-Za-z_][A-Za-z0-9_]*)\b")

for source in (repo_root / "Sources").rglob("*.swift"):
    current_enum = None
    depth = 0
    for line in source.read_text().splitlines():
        if current_enum is None:
            match = enum_pattern.search(line)
            if match and match.group(1) in guarded_enums:
                current_enum = match.group(1)
                seen_enums.add(current_enum)
                depth = line.count("{") - line.count("}")
            continue

        stripped = line.strip()
        if depth == 1 and (stripped.startswith("case ") or stripped.startswith("indirect case ")):
            prefix = "indirect case " if stripped.startswith("indirect case ") else "case "
            case_part = stripped.split("//", 1)[0][len(prefix):].strip()
            for part in split_cases(case_part):
                match = case_name_pattern.match(part)
                if match:
                    actual.add(f"{current_enum}.{match.group(1)}")

        depth += line.count("{") - line.count("}")
        if depth <= 0:
            current_enum = None

missing_enums = guarded_enums - seen_enums
added = sorted(actual - expected)
removed = sorted(expected - actual)

if missing_enums or added or removed:
    print("::error::Provisionally stable enum case ledger drift", file=sys.stderr)
    if missing_enums:
        print("Missing guarded enums:", file=sys.stderr)
        for item in sorted(missing_enums):
            print(f"  - {item}", file=sys.stderr)
    if added:
        print("New source cases not in allowlist:", file=sys.stderr)
        for item in added:
            print(f"  - {item}", file=sys.stderr)
    if removed:
        print("Allowlisted cases no longer found in source:", file=sys.stderr)
        for item in removed:
            print(f"  - {item}", file=sys.stderr)
    print(
        "Update API_STABILITY.md and migration/release notes before changing "
        "Scripts/enum-cases/provisional-enum-cases.allowlist.",
        file=sys.stderr,
    )
    sys.exit(1)

print("✅ Provisionally stable enum case ledger is in sync.")
PY
