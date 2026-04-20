#!/usr/bin/env bash
# Verifies that the three TestClock.swift copies (one per test target) stay
# byte-for-byte identical below their `@testable import` header. SwiftPM has
# no first-class way to share source between testTargets, so we replicate;
# this guard catches drift early.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

files=(
  "Tests/InnoNetworkTests/TestClock.swift"
  "Tests/InnoNetworkDownloadTests/TestClock.swift"
  "Tests/InnoNetworkWebSocketTests/TestClock.swift"
)

for file in "${files[@]}"; do
  if [[ ! -f "$file" ]]; then
    echo "verify_testclock_parity: missing expected file: $file" >&2
    exit 1
  fi
done

# Strip the top import block (every line starting with `import` or
# `@testable import`, plus the blank line right after). Compare bodies.
extract_body() {
  awk '
    BEGIN { in_header = 1 }
    in_header && ($0 ~ /^import / || $0 ~ /^@testable import / || $0 ~ /^[[:space:]]*$/) { next }
    { in_header = 0; print }
  ' "$1"
}

reference_body="$(extract_body "${files[0]}")"
drift=0

for file in "${files[@]:1}"; do
  current_body="$(extract_body "$file")"
  if [[ "$reference_body" != "$current_body" ]]; then
    echo "verify_testclock_parity: drift detected in $file" >&2
    diff -u \
      <(printf '%s\n' "$reference_body") \
      <(printf '%s\n' "$current_body") >&2 || true
    drift=1
  fi
done

if [[ "$drift" -ne 0 ]]; then
  exit 1
fi

echo "verify_testclock_parity: OK (${#files[@]} copies in sync)"
