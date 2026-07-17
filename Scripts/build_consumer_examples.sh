#!/usr/bin/env bash
set -euo pipefail

repo_root="${INNO_CONSUMER_EXAMPLES_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
list_only=0

usage() {
  cat <<'USAGE'
Usage: bash Scripts/build_consumer_examples.sh [--list]

Discover every independent Examples/*/Package.swift manifest and build it.

  --list  Print the discovered package directories without building them.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --list)
      list_only=1
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      echo "consumer-example-builder: unknown argument: $1" >&2
      usage >&2
      exit 64
      ;;
  esac
  shift
done

manifests=()
while IFS= read -r manifest; do
  manifests+=("$manifest")
done < <(
  find "$repo_root/Examples" \
    -mindepth 2 -maxdepth 2 -name Package.swift -type f -print | sort
)

if [[ ${#manifests[@]} -eq 0 ]]; then
  echo "consumer-example-builder: no independent example manifests found" >&2
  exit 1
fi

if (( list_only == 0 )) && ! command -v xcrun >/dev/null 2>&1; then
  echo "consumer-example-builder: required command is unavailable: xcrun" >&2
  exit 69
fi

for manifest in "${manifests[@]}"; do
  package_path="$(dirname "$manifest")"
  relative_path="${package_path#"$repo_root"/}"
  if (( list_only == 1 )); then
    printf '%s\n' "$relative_path"
    continue
  fi

  echo "Building consumer example: $relative_path"
  xcrun swift build --package-path "$package_path"
done

if (( list_only == 0 )); then
  echo "consumer-example-builder: built ${#manifests[@]} package(s)"
fi
