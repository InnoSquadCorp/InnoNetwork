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

    targets = package.get("targets")
    if not isinstance(targets, list):
        fail("The package dump must contain a targets array.")

    inno_network_targets = [
        target
        for target in targets
        if isinstance(target, dict) and target.get("name") == "InnoNetwork"
    ]
    if len(inno_network_targets) != 1:
        fail("The package must contain exactly one InnoNetwork target.")

    macro_targets = [
        target
        for target in targets
        if isinstance(target, dict) and target.get("name") == "InnoNetworkMacros"
    ]
    if len(macro_targets) != 1 or macro_targets[0].get("type") != "macro":
        fail("The package must contain exactly one InnoNetworkMacros macro target.")

    dependencies = inno_network_targets[0].get("dependencies")
    if not isinstance(dependencies, list):
        fail("The InnoNetwork target must contain a dependencies array.")

    macro_dependencies = []
    for dependency in dependencies:
        if not isinstance(dependency, dict):
            continue
        target_dependency = dependency.get("target")
        if (
            isinstance(target_dependency, list)
            and target_dependency
            and target_dependency[0] == "InnoNetworkMacros"
        ):
            macro_dependencies.append(target_dependency)

    if len(macro_dependencies) != 1:
        fail("InnoNetwork must contain exactly one InnoNetworkMacros dependency.")

    macro_dependency = macro_dependencies[0]
    if len(macro_dependency) != 2 or not isinstance(macro_dependency[1], dict):
        fail("The InnoNetworkMacros dependency must have a trait condition.")

    dependency_condition = macro_dependency[1]
    condition_traits = dependency_condition.get("traits")
    if condition_traits != ["Macros"]:
        fail("The InnoNetworkMacros dependency must be conditioned only on Macros.")

    condition_platforms = dependency_condition.get("platformNames", [])
    if condition_platforms != []:
        fail(
            "The InnoNetworkMacros dependency must remain available on all "
            "declared platforms."
        )


if __name__ == "__main__":
    main()
