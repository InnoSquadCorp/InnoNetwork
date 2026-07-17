#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
runner="$repo_root/Scripts/build_consumer_examples.sh"
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/innonetwork-consumer-example-builder-tests.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT

fixture_root="$work_dir/repository"
mkdir -p \
  "$fixture_root/Examples/Alpha" \
  "$fixture_root/Examples/Zeta" \
  "$work_dir/bin"
touch \
  "$fixture_root/Examples/Alpha/Package.swift" \
  "$fixture_root/Examples/Zeta/Package.swift"

cat > "$work_dir/expected-list.txt" <<'EOF'
Examples/Alpha
Examples/Zeta
EOF
INNO_CONSUMER_EXAMPLES_ROOT="$fixture_root" \
  bash "$runner" --list > "$work_dir/actual-list.txt"
diff -u "$work_dir/expected-list.txt" "$work_dir/actual-list.txt"

cat > "$work_dir/bin/xcrun" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$INNO_CONSUMER_EXAMPLES_TEST_LOG"
EOF
chmod +x "$work_dir/bin/xcrun"

cat > "$work_dir/expected-builds.txt" <<EOF
swift build --package-path $fixture_root/Examples/Alpha
swift build --package-path $fixture_root/Examples/Zeta
EOF
PATH="$work_dir/bin:$PATH" \
  INNO_CONSUMER_EXAMPLES_ROOT="$fixture_root" \
  INNO_CONSUMER_EXAMPLES_TEST_LOG="$work_dir/actual-builds.txt" \
  bash "$runner" > "$work_dir/build.stdout"
diff -u "$work_dir/expected-builds.txt" "$work_dir/actual-builds.txt"
grep -Fq 'consumer-example-builder: built 2 package(s)' "$work_dir/build.stdout"

empty_root="$work_dir/empty"
mkdir -p "$empty_root/Examples"
if INNO_CONSUMER_EXAMPLES_ROOT="$empty_root" bash "$runner" --list \
  > "$work_dir/empty.stdout" 2> "$work_dir/empty.stderr"; then
  echo "Expected an empty example set to fail." >&2
  exit 1
fi
grep -Fq 'no independent example manifests found' "$work_dir/empty.stderr"

set +e
INNO_CONSUMER_EXAMPLES_ROOT="$fixture_root" bash "$runner" --unknown \
  > "$work_dir/unknown.stdout" 2> "$work_dir/unknown.stderr"
status=$?
set -e
if [[ "$status" -ne 64 ]]; then
  echo "Expected an unknown argument to exit 64; got $status." >&2
  exit 1
fi
grep -Fq 'unknown argument: --unknown' "$work_dir/unknown.stderr"

echo "Consumer example builder tests passed."
