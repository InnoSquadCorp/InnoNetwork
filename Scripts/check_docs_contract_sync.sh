#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

api_stability="$repo_root/API_STABILITY.md"
readme="$repo_root/README.md"
required_meta_docs=(
  "$repo_root/CONTRIBUTING.md"
  "$repo_root/CODE_OF_CONDUCT.md"
  "$repo_root/SECURITY.md"
  "$repo_root/SUPPORT.md"
  "$repo_root/CHANGELOG.md"
  "$repo_root/docs/RELEASE_POLICY.md"
  "$repo_root/docs/MIGRATION_POLICY.md"
)
example_docs=(
  "$repo_root/Examples/BasicRequest/README.md"
  "$repo_root/Examples/CustomHeaders/README.md"
  "$repo_root/Examples/ErrorHandling/README.md"
  "$repo_root/Examples/RealWorldAPI/README.md"
  "$repo_root/Examples/README.md"
)

fail() {
  echo "docs-contract-sync: $1" >&2
  exit 1
}

has_rg() {
  command -v rg > /dev/null 2>&1
}

require_line() {
  local needle="$1"
  local file="$2"
  if has_rg; then
    rg -Fqx "$needle" "$file" > /dev/null || fail "missing line '$needle' in $file"
  else
    grep -Fqx "$needle" "$file" > /dev/null || fail "missing line '$needle' in $file"
  fi
}

require_contains() {
  local needle="$1"
  local file="$2"
  if has_rg; then
    rg -Fq "$needle" "$file" || fail "missing '$needle' in $file"
  else
    grep -Fq "$needle" "$file" || fail "missing '$needle' in $file"
  fi
}

forbidden_pattern() {
  local pattern="$1"
  shift
  if has_rg; then
    if rg -n "$pattern" "$@" > /dev/null; then
      rg -n "$pattern" "$@" >&2
      fail "forbidden legacy documentation pattern matched: $pattern"
    fi
    return
  fi

  if grep -En "$pattern" "$@" > /dev/null; then
    grep -En "$pattern" "$@" >&2
    fail "forbidden legacy documentation pattern matched: $pattern"
  fi
}

require_line "## Stable" "$api_stability"
require_line "## Provisionally Stable" "$api_stability"
require_line "## Internal/Operational" "$api_stability"

expected_stable=(
'`APIDefinition`'
'`MultipartAPIDefinition`'
'`ProtobufAPIDefinition`'
'`DefaultNetworkClient`'
'`NetworkConfiguration.safeDefaults(baseURL:)`'
'`NetworkConfiguration.advanced(baseURL:_:)`'
'`DownloadConfiguration.safeDefaults()`'
'`DownloadConfiguration.advanced(_:)`'
'`WebSocketConfiguration.safeDefaults()`'
'`WebSocketConfiguration.advanced(_:)`'
'`DownloadManager`'
'`WebSocketManager`'
'`TrustPolicy`'
'`AnyResponseDecoder`'
'`URLQueryEncoder`'
'`EventDeliveryPolicy`'
)

documented_stable=()
while IFS= read -r line; do
  documented_stable+=("$line")
done < <(
  awk '
    /^## Stable$/ { in_section = 1; next }
    /^## / { if (in_section) exit }
    in_section && /^- / {
      sub(/^- /, "")
      print
    }
  ' "$api_stability"
)

expected_sorted="$(printf '%s\n' "${expected_stable[@]}" | sort)"
documented_sorted="$(printf '%s\n' "${documented_stable[@]:-}" | sort)"
[[ "$expected_sorted" == "$documented_sorted" ]] || {
  echo "Expected Stable symbols:" >&2
  printf '%s\n' "${expected_stable[@]}" >&2
  echo "Documented Stable symbols:" >&2
  printf '%s\n' "${documented_stable[@]:-}" >&2
  fail "Stable symbol list in API_STABILITY.md does not match expected allowlist"
}

for symbol in "${expected_stable[@]}"; do
  case "$symbol" in
    '`APIDefinition`')
      pattern='public protocol APIDefinition'
      target="$repo_root/Sources/InnoNetwork/APIDefinition.swift"
      ;;
    '`MultipartAPIDefinition`')
      pattern='public protocol MultipartAPIDefinition'
      target="$repo_root/Sources/InnoNetwork/APIDefinition.swift"
      ;;
    '`ProtobufAPIDefinition`')
      pattern='public protocol ProtobufAPIDefinition'
      target="$repo_root/Sources/InnoNetwork/ProtobufAPIDefinition.swift"
      ;;
    '`DefaultNetworkClient`')
      pattern='public actor DefaultNetworkClient'
      target="$repo_root/Sources/InnoNetwork/DefaultNetworkClient.swift"
      ;;
    '`NetworkConfiguration.safeDefaults(baseURL:)`')
      pattern='public static func safeDefaults(baseURL: URL)'
      target="$repo_root/Sources/InnoNetwork/NetworkConfiguration.swift"
      ;;
    '`NetworkConfiguration.advanced(baseURL:_:)`')
      pattern='public static func advanced('
      target="$repo_root/Sources/InnoNetwork/NetworkConfiguration.swift"
      ;;
    '`DownloadConfiguration.safeDefaults()`')
      pattern='public static func safeDefaults()'
      target="$repo_root/Sources/InnoNetworkDownload/DownloadConfiguration.swift"
      ;;
    '`DownloadConfiguration.advanced(_:)`')
      pattern='public static func advanced('
      target="$repo_root/Sources/InnoNetworkDownload/DownloadConfiguration.swift"
      ;;
    '`WebSocketConfiguration.safeDefaults()`')
      pattern='public static func safeDefaults()'
      target="$repo_root/Sources/InnoNetworkWebSocket/WebSocketConfiguration.swift"
      ;;
    '`WebSocketConfiguration.advanced(_:)`')
      pattern='public static func advanced('
      target="$repo_root/Sources/InnoNetworkWebSocket/WebSocketConfiguration.swift"
      ;;
    '`DownloadManager`')
      pattern='public final class DownloadManager'
      target="$repo_root/Sources/InnoNetworkDownload/DownloadManager.swift"
      ;;
    '`WebSocketManager`')
      pattern='public final class WebSocketManager'
      target="$repo_root/Sources/InnoNetworkWebSocket/WebSocketManager.swift"
      ;;
    '`TrustPolicy`')
      pattern='public enum TrustPolicy'
      target="$repo_root/Sources/InnoNetwork/TrustPolicy.swift"
      ;;
    '`AnyResponseDecoder`')
      pattern='public struct AnyResponseDecoder'
      target="$repo_root/Sources/InnoNetwork/AnyResponseDecoder.swift"
      ;;
    '`URLQueryEncoder`')
      pattern='public struct URLQueryEncoder'
      target="$repo_root/Sources/InnoNetwork/URLQueryEncoder.swift"
      ;;
    '`EventDeliveryPolicy`')
      pattern='public struct EventDeliveryPolicy'
      target="$repo_root/Sources/InnoNetwork/EventPipeline.swift"
      ;;
    *)
      fail "unknown stable symbol mapping: $symbol"
      ;;
  esac

  if has_rg; then
    rg -Fq "$pattern" "$target" || fail "stable symbol $symbol is not present in production sources"
  else
    grep -Fq "$pattern" "$target" || fail "stable symbol $symbol is not present in production sources"
  fi
done

require_contains "API Stability" "$readme"
require_contains ".safeDefaults(" "$readme"
require_contains "CONTRIBUTING.md" "$readme"
require_contains "SECURITY.md" "$readme"
require_contains "SUPPORT.md" "$readme"
require_contains "docs/RELEASE_POLICY.md" "$readme"

for doc in "${required_meta_docs[@]}"; do
  [[ -f "$doc" ]] || fail "required OSS document is missing: $doc"
done

for doc in "${example_docs[@]}"; do
  require_contains "safeDefaults" "$doc"
done

forbidden_pattern 'configuration:\s*NetworkConfiguration\(' "$readme" "${example_docs[@]}"
forbidden_pattern 'let configuration = NetworkConfiguration\(' "$readme" "${example_docs[@]}"
forbidden_pattern 'let client = DefaultNetworkClient\(\s*configuration:\s*\.default' "$readme" "${example_docs[@]}"
forbidden_pattern 'addText|addFile' "$readme" "${example_docs[@]}"
forbidden_pattern 'from:\s*"1\.0\.0"' "$readme" "${example_docs[@]}"

echo "docs-contract-sync: OK"
