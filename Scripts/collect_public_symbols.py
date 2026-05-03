#!/usr/bin/env python3
import json
import sys
from pathlib import Path


def main() -> None:
    repo_root = Path(sys.argv[1])
    symbolgraph_dirs = [path for path in (repo_root / ".build").glob("*/symbolgraph") if path.is_dir()]
    if not symbolgraph_dirs:
        raise SystemExit("No Swift symbol graph directory was generated.")

    symbolgraph_dir = max(symbolgraph_dirs, key=lambda path: path.stat().st_mtime)
    included_modules = {
        "InnoNetwork",
        "InnoNetworkDownload",
        "InnoNetworkPersistentCache",
        "InnoNetworkWebSocket",
        "InnoNetworkTestSupport",
    }
    included_kinds = {
        "swift.actor",
        "swift.associatedtype",
        "swift.class",
        "swift.enum",
        "swift.enum.case",
        "swift.func",
        "swift.init",
        "swift.macro",
        "swift.method",
        "swift.property",
        "swift.protocol",
        "swift.struct",
        "swift.type.method",
        "swift.type.property",
        "swift.typealias",
    }
    rows: set[str] = set()
    seen_modules: set[str] = set()

    for path in sorted(symbolgraph_dir.glob("*.symbols.json")):
        if "@" in path.name or path.name.startswith("InnoNetworkPackageTests"):
            continue
        with path.open(encoding="utf-8") as handle:
            data = json.load(handle)
        module = data.get("module", {}).get("name")
        if module not in included_modules:
            continue
        seen_modules.add(module)
        for symbol in data.get("symbols", []):
            if symbol.get("accessLevel") != "public":
                continue
            kind = symbol.get("kind", {}).get("identifier")
            if kind not in included_kinds:
                continue
            components = symbol.get("pathComponents") or []
            if not components:
                continue
            rows.add(f"{module}\t{kind}\t{'.'.join(components)}")

    missing_modules = sorted(included_modules - seen_modules)
    if missing_modules:
        raise SystemExit(f"Missing required symbol graphs: {', '.join(missing_modules)}")

    for row in sorted(rows):
        print(row)


if __name__ == "__main__":
    main()
