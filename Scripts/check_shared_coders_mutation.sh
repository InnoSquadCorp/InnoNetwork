#!/usr/bin/env bash
# Forbids mutation of the cached `SharedCoders.requestEncoder` /
# `SharedCoders.responseDecoder` instances.
#
# These coders are shared across concurrent requests and treated as
# immutable after module load. The cross-thread safety contract relies
# on no caller assigning to `dateDecodingStrategy`, `keyEncodingStrategy`,
# `userInfo`, or any other property on them. Any new use must invoke
# only `decode(_:from:)` / `encode(_:)`.
#
# This guard catches the common syntactic mistake — assignment through
# the singleton — at PR review time. Indirect mutation through a
# captured reference is rare enough that a code reviewer is the right
# layer of defense; this script complements that with a fast, automatic
# rejection of the obvious case.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

scan_paths=(
    "$repo_root/Sources"
    "$repo_root/Tests"
)

violations="$(mktemp)"
trap 'rm -f "$violations"' EXIT

for path in "${scan_paths[@]}"; do
    if [[ ! -d "$path" ]]; then continue; fi
    while IFS= read -r -d '' file; do
        # Match `SharedCoders.<member>.<property> =` (assignment) and
        # likewise the appending compound forms. The pattern excludes
        # `==` and `!=` so equality checks are still permitted.
        # Match `SharedCoders.<member>.<property>` followed by an
        # assignment operator. The operator class includes plain `=`
        # plus the compound forms `+=`, `-=`, `*=`, `/=`, and the
        # nil-coalesce update `??=`. The lookbehind on the second
        # character rejects `==` / `!=` (equality, not assignment).
        if grep -nE 'SharedCoders\.[A-Za-z_][A-Za-z0-9_]*\.[A-Za-z_][A-Za-z0-9_]*[[:space:]]*(=|[-+*/]=|\?\?=)([^=]|$)' "$file" \
            >> "$violations"; then
            :
        fi
    done < <(find "$path" -name '*.swift' -type f -print0)
done

if [[ -s "$violations" ]]; then
    echo "::error::SharedCoders mutation detected — these coders are immutable after module load"
    cat "$violations"
    exit 1
fi

echo "✅ No mutation of SharedCoders.requestEncoder / SharedCoders.responseDecoder."
