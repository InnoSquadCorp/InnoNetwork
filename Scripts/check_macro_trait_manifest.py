#!/usr/bin/env python3

import json
import sys
from pathlib import Path


def fail(message: str) -> None:
    raise SystemExit(message)


def main() -> None:
    if len(sys.argv) != 2:
        fail("Usage: check_macro_trait_manifest.py <package-dump.json>")

    with Path(sys.argv[1]).open(encoding="utf-8") as source:
        package = json.load(source)

    traits = package.get("traits")
    if not isinstance(traits, list):
        fail("The package dump must contain a traits array.")

    by_name: dict[str, dict] = {}
    for trait in traits:
        if not isinstance(trait, dict) or not isinstance(trait.get("name"), str):
            fail("The package dump contains an invalid trait entry.")
        if trait["name"] in by_name:
            fail(f"Duplicate package trait: {trait['name']}")
        by_name[trait["name"]] = trait

    if "Macros" not in by_name:
        fail("The Macros package trait must remain declared.")

    default_traits = by_name.get("default", {}).get("enabledTraits")
    if not isinstance(default_traits, list) or "Macros" not in default_traits:
        fail("The Macros package trait must remain enabled by default.")


if __name__ == "__main__":
    main()
