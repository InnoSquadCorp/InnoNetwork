#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <docc-derived-data-path>" >&2
  exit 64
fi

repo_root="${INNO_DOCC_CONTRACT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
derived_data_path="$1"
if [[ "$derived_data_path" != /* ]]; then
  derived_data_path="$repo_root/$derived_data_path"
fi

python3 - "$repo_root" "$derived_data_path" <<'PY'
import collections
import json
import os
import pathlib
import re
import subprocess
import sys


repo_root = pathlib.Path(sys.argv[1])
derived_data_path = pathlib.Path(sys.argv[2])
contract_path = repo_root / "docs/public-docc-products.txt"
products_path = derived_data_path / "Build/Products"


def fail(message: str) -> None:
    print(f"docc-archive-contract: {message}", file=sys.stderr)
    raise SystemExit(1)


products = contract_path.read_text(encoding="utf-8").splitlines()
if not products:
    fail(f"public product contract is empty: {contract_path}")
if any(not product or product != product.strip() for product in products):
    fail("public product entries must be nonempty lines without surrounding whitespace")

identifier_pattern = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")
invalid = [product for product in products if identifier_pattern.fullmatch(product) is None]
if invalid:
    fail(f"invalid Swift product identifier(s): {', '.join(invalid)}")

duplicates = [
    product
    for product, count in collections.Counter(products).items()
    if count > 1
]
if duplicates:
    fail(f"duplicate public product(s): {', '.join(sorted(duplicates))}")

package_json_override = os.environ.get("INNO_DOCC_PACKAGE_JSON")
if package_json_override:
    package_payload = pathlib.Path(package_json_override).read_text(encoding="utf-8")
else:
    completed = subprocess.run(
        [
            "xcrun",
            "swift",
            "package",
            "--package-path",
            str(repo_root),
            "dump-package",
        ],
        check=True,
        capture_output=True,
        text=True,
    )
    package_payload = completed.stdout

package = json.loads(package_payload)
library_products = [
    product["name"]
    for product in package.get("products", [])
    if isinstance(product, dict)
    and isinstance(product.get("type"), dict)
    and "library" in product["type"]
]
if products != library_products:
    missing = sorted(set(library_products) - set(products))
    unexpected = sorted(set(products) - set(library_products))
    details = []
    if missing:
        details.append("missing " + ", ".join(missing))
    if unexpected:
        details.append("unexpected " + ", ".join(unexpected))
    if not details:
        details.append("order differs from Package.swift")
    fail("public product contract does not match Package.swift (" + "; ".join(details) + ")")

if not products_path.is_dir():
    fail(f"DocC products directory is missing: {products_path}")

archives_by_product = collections.defaultdict(list)
for archive in products_path.glob("*/*.doccarchive"):
    if archive.is_dir():
        archives_by_product[archive.name.removesuffix(".doccarchive")].append(archive)

for product in products:
    archives = sorted(archives_by_product[product])
    if len(archives) != 1:
        fail(
            f"expected exactly one {product}.doccarchive under {products_path}; "
            f"found {len(archives)}"
        )

print(f"docc-archive-contract: OK ({len(products)} public product archives)")
PY
