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
  "$repo_root/docs/releases/4.0.0.md"
)
required_feature_docs=(
  "$repo_root/Sources/InnoNetwork/InnoNetwork.docc/Articles/EventDeliveryPolicy.md"
  "$repo_root/Sources/InnoNetwork/InnoNetwork.docc/InnoNetwork.md"
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
'`DefaultNetworkClient`'
'`NetworkClient.request(_:)`'
'`NetworkClient.upload(_:)`'
'`NetworkConfiguration.safeDefaults(baseURL:)`'
'`NetworkConfiguration.advanced(baseURL:_:)`'
'`DownloadConfiguration.safeDefaults()`'
'`DownloadConfiguration.advanced(_:)`'
'`WebSocketConfiguration.safeDefaults()`'
'`WebSocketConfiguration.advanced(_:)`'
'`DownloadManager`'
'`WebSocketManager`'
'`WebSocketEvent.ping`'
'`WebSocketEvent.pong`'
'`WebSocketEvent.error(.pingTimeout)`'
'`WebSocketPingContext`'
'`WebSocketPongContext`'
'`TrustPolicy`'
'`AnyResponseDecoder`'
'`URLQueryEncoder`'
'`EventDeliveryPolicy`'
'`WebSocketCloseCode`'
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

expected_provisionally=(
'`default` aliases on configuration types'
'benchmark runner CLI flags and JSON summary presentation details'
'troubleshooting guidance and examples in README/DocC'
'`InnoNetworkTestSupport` library product and its `public` symbols'
'`Endpoint`, `AnyEncodable`, `NetworkContext`, and `CorrelationIDInterceptor`'
)

expected_shipping_public_declarations=(
  APIDefinition
  AnyEncodable
  AnyResponseDecoder
  ContentType
  CorrelationIDInterceptor
  DefaultNetworkClient
  DefaultNetworkLogger
  DownloadConfiguration
  DownloadError
  DownloadEvent
  DownloadEventSubscription
  DownloadManager
  DownloadManagerError
  DownloadProgress
  DownloadState
  DownloadTask
  EmptyParameter
  EmptyResponse
  Endpoint
  EventDeliveryPolicy
  EventPipelineAggregateSnapshotMetric
  EventPipelineConsumerDeliveryLatencyMetric
  EventPipelineConsumerStateMetric
  EventPipelineHubKind
  EventPipelineMetric
  EventPipelineMetricsReporting
  EventPipelineOverflowPolicy
  EventPipelinePartitionStateMetric
  ExponentialBackoffRetryPolicy
  HTTPEmptyResponseDecodable
  HTTPHeader
  HTTPHeaders
  HTTPMethod
  MultipartAPIDefinition
  MultipartFormData
  MultipartUploadStrategy
  NetworkClient
  NetworkConfiguration
  NetworkContext
  NetworkError
  NetworkEvent
  NetworkEventObserving
  NetworkInterfaceType
  NetworkLoggingOptions
  NetworkLogger
  NetworkMetricsReporting
  NetworkMonitor
  NetworkMonitoring
  NetworkReachabilityStatus
  NetworkRequestContext
  NetworkSnapshot
  NoOpEventPipelineMetricsReporter
  NoOpNetworkEventObserver
  NoOpNetworkLogger
  OSLogNetworkEventObserver
  PublicKeyPinningPolicy
  RequestInterceptor
  Response
  ResponseInterceptor
  RetryDecision
  RetryPolicy
  SendableUnderlyingError
  ServerSentEvent
  ServerSentEventDecoder
  StreamingAPIDefinition
  StreamingResumePolicy
  TimeoutReason
  TrustEvaluating
  TrustFailureReason
  TrustPolicy
  URLQueryCustomKeyTransform
  URLQueryEncoder
  URLQueryKeyEncodingStrategy
  URLSessionProtocol
  WebSocketCloseCode
  WebSocketCloseDisposition
  WebSocketConfiguration
  WebSocketError
  WebSocketEvent
  WebSocketEventSubscription
  WebSocketManager
  WebSocketPingContext
  WebSocketPongContext
  WebSocketSendOverflowPolicy
  WebSocketState
  WebSocketTask
)

expected_spi_public_declarations=(
  LowLevelNetworkClient
  RequestPayload
  SingleRequestExecutable
)

expected_test_support_public_declarations=(
  StubBehavior
  StubNetworkClient
  StubRequestKey
  WebSocketEventRecorder
)

validate_protocol_symbol() {
  local protocol_name="$1"
  local target="$2"
  local pattern="$3"

  if has_rg; then
    awk -v protocol_name="$protocol_name" '
      $0 ~ "^public protocol " protocol_name ": Sendable \\{$" { in_protocol = 1; next }
      in_protocol && /^\}$/ { exit }
      in_protocol { print }
    ' "$target" | rg -q "$pattern" || fail "symbol matching $pattern is not present in $protocol_name protocol"
  else
    awk -v protocol_name="$protocol_name" '
      $0 ~ "^public protocol " protocol_name ": Sendable \\{$" { in_protocol = 1; next }
      in_protocol && /^\}$/ { exit }
      in_protocol { print }
    ' "$target" | grep -Eq "$pattern" || fail "symbol matching $pattern is not present in $protocol_name protocol"
  fi
}

validate_default_aliases() {
  require_contains 'public static let `default` = safeDefaults()' "$repo_root/Sources/InnoNetworkDownload/DownloadConfiguration.swift"
  require_contains 'public static let `default` = safeDefaults()' "$repo_root/Sources/InnoNetworkWebSocket/WebSocketConfiguration.swift"
}

validate_benchmark_docs() {
  require_contains 'swift run InnoNetworkBenchmarks --quick' "$readme"
  require_contains 'swift run InnoNetworkBenchmarks --json-path /tmp/innonetwork-bench.json' "$readme"
  require_contains 'JSON summary' "$repo_root/Benchmarks/README.md"
  require_contains '"results"' "$repo_root/Benchmarks/README.md"
}

validate_test_support_product() {
  require_contains 'name: "InnoNetworkTestSupport"' "$repo_root/Package.swift"
  require_contains 'targets: ["InnoNetworkTestSupport"]' "$repo_root/Package.swift"
  require_contains 'public final class WebSocketEventRecorder' \
    "$repo_root/Sources/InnoNetworkTestSupport/WebSocketEventRecorder.swift"
  require_contains 'public enum StubBehavior: Sendable, Equatable' \
    "$repo_root/Sources/InnoNetworkTestSupport/StubNetworkClient.swift"
  require_contains 'public struct StubRequestKey: Hashable, Sendable' \
    "$repo_root/Sources/InnoNetworkTestSupport/StubNetworkClient.swift"
  require_contains 'public final class StubNetworkClient' \
    "$repo_root/Sources/InnoNetworkTestSupport/StubNetworkClient.swift"
}

collect_public_declarations() {
  local include_spi="$1"
  shift
  find "$@" -type f -name '*.swift' | sort | while IFS= read -r file; do
    awk -v include_spi="$include_spi" '
      function emit(line) {
        if (line ~ /^public final class /) {
          sub(/^public final class /, "", line)
        } else if (line ~ /^public (protocol|struct|enum|class|actor) /) {
          sub(/^public (protocol|struct|enum|class|actor) /, "", line)
        } else {
          return
        }
        sub(/[<:({ ].*/, "", line)
        print line
      }

      /^@_spi\([^)]*\) public / {
        if (include_spi == "yes") {
          line = $0
          sub(/^@_spi\([^)]*\) /, "", line)
          emit(line)
        }
        next
      }

      /^public / {
        if (include_spi == "no") {
          emit($0)
        }
      }
    ' "$file"
  done | sort -u
}

validate_public_declaration_set() {
  local label="$1"
  local actual="$2"
  shift 2
  local expected
  expected="$(printf '%s\n' "$@" | sort -u)"

  [[ "$expected" == "$actual" ]] || {
    echo "Expected $label public declarations:" >&2
    printf '%s\n' "$expected" >&2
    echo "Actual $label public declarations:" >&2
    printf '%s\n' "$actual" >&2
    fail "$label public declaration set drifted; update API_STABILITY.md and check_docs_contract_sync.sh"
  }
}

validate_public_surface_ledger() {
  local shipping_actual
  shipping_actual="$(
    collect_public_declarations no \
      "$repo_root/Sources/InnoNetwork" \
      "$repo_root/Sources/InnoNetworkDownload" \
      "$repo_root/Sources/InnoNetworkWebSocket"
  )"
  validate_public_declaration_set \
    "shipping" \
    "$shipping_actual" \
    "${expected_shipping_public_declarations[@]}"

  local spi_actual
  spi_actual="$(
    collect_public_declarations yes \
      "$repo_root/Sources/InnoNetwork" \
      "$repo_root/Sources/InnoNetworkDownload" \
      "$repo_root/Sources/InnoNetworkWebSocket"
  )"
  validate_public_declaration_set \
    "SPI" \
    "$spi_actual" \
    "${expected_spi_public_declarations[@]}"

  local test_support_actual
  test_support_actual="$(collect_public_declarations no "$repo_root/Sources/InnoNetworkTestSupport")"
  validate_public_declaration_set \
    "TestSupport" \
    "$test_support_actual" \
    "${expected_test_support_public_declarations[@]}"

  for declaration in "${expected_shipping_public_declarations[@]}" "${expected_spi_public_declarations[@]}" \
    "${expected_test_support_public_declarations[@]}"; do
    require_contains "\`$declaration\`" "$api_stability"
  done
}

validate_oss_readiness_public_api() {
  require_contains 'public struct Endpoint<Response: Decodable & Sendable>: APIDefinition' \
    "$repo_root/Sources/InnoNetwork/Endpoint.swift"
  require_contains 'public struct AnyEncodable: Encodable, Sendable' \
    "$repo_root/Sources/InnoNetwork/AnyEncodable.swift"
  require_contains 'public struct NetworkContext: Sendable' \
    "$repo_root/Sources/InnoNetwork/NetworkContext.swift"
  require_contains 'public struct CorrelationIDInterceptor: RequestInterceptor' \
    "$repo_root/Sources/InnoNetwork/CorrelationIDInterceptor.swift"
}

validate_troubleshooting_and_examples_docs() {
  require_contains 'Examples: [Examples/README.md](Examples/README.md)' "$readme"
  require_contains 'API Stability: [API_STABILITY.md](API_STABILITY.md)' "$readme"
  require_contains 'Upcoming Release Notes: [docs/releases/4.0.0.md](docs/releases/4.0.0.md)' "$readme"
  require_contains '### 1. [BasicRequest](./BasicRequest)' "$repo_root/Examples/README.md"
  require_contains '### 2. [ErrorHandling](./ErrorHandling)' "$repo_root/Examples/README.md"
  require_contains '### 3. [CustomHeaders](./CustomHeaders)' "$repo_root/Examples/README.md"
  require_contains '### 4. [RealWorldAPI](./RealWorldAPI)' "$repo_root/Examples/README.md"
  require_contains '### [ConsumerSmoke](./ConsumerSmoke)' "$repo_root/Examples/README.md"
  require_contains '### [WrapperSmoke](./WrapperSmoke)' "$repo_root/Examples/README.md"
}

documented_provisionally=()
while IFS= read -r line; do
  documented_provisionally+=("$line")
done < <(
  awk '
    /^## Provisionally Stable$/ { in_section = 1; next }
    /^## / { if (in_section) exit }
    in_section && /^- / {
      sub(/^- /, "")
      print
    }
  ' "$api_stability"
)

expected_provisionally_sorted="$(printf '%s\n' "${expected_provisionally[@]}" | sort)"
documented_provisionally_sorted="$(printf '%s\n' "${documented_provisionally[@]:-}" | sort)"
[[ "$expected_provisionally_sorted" == "$documented_provisionally_sorted" ]] || {
  echo "Expected Provisionally Stable symbols:" >&2
  printf '%s\n' "${expected_provisionally[@]}" >&2
  echo "Documented Provisionally Stable symbols:" >&2
  printf '%s\n' "${documented_provisionally[@]:-}" >&2
  fail "Provisionally Stable symbol list in API_STABILITY.md does not match expected allowlist"
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
    '`DefaultNetworkClient`')
      pattern='public final class DefaultNetworkClient'
      target="$repo_root/Sources/InnoNetwork/DefaultNetworkClient.swift"
      ;;
    '`NetworkClient.request(_:)`')
      pattern='^    func request<T: APIDefinition>\(_ request: T\) async throws -> T\.APIResponse$'
      target="$repo_root/Sources/InnoNetwork/DefaultNetworkClient.swift"
      ;;
    '`NetworkClient.upload(_:)`')
      pattern='^    func upload<T: MultipartAPIDefinition>\(_ request: T\) async throws -> T\.APIResponse$'
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
      pattern='public actor DownloadManager'
      target="$repo_root/Sources/InnoNetworkDownload/DownloadManager.swift"
      ;;
    '`WebSocketManager`')
      pattern='public final class WebSocketManager'
      target="$repo_root/Sources/InnoNetworkWebSocket/WebSocketManager.swift"
      ;;
    '`WebSocketEvent.ping`')
      pattern='case ping(WebSocketPingContext)'
      target="$repo_root/Sources/InnoNetworkWebSocket/WebSocketManager.swift"
      ;;
    '`WebSocketEvent.pong`')
      pattern='case pong(WebSocketPongContext)'
      target="$repo_root/Sources/InnoNetworkWebSocket/WebSocketManager.swift"
      ;;
    '`WebSocketEvent.error(.pingTimeout)`')
      pattern='case error(WebSocketError)'
      target="$repo_root/Sources/InnoNetworkWebSocket/WebSocketManager.swift"
      ;;
    '`WebSocketPingContext`')
      pattern='public struct WebSocketPingContext'
      target="$repo_root/Sources/InnoNetworkWebSocket/WebSocketManager.swift"
      ;;
    '`WebSocketPongContext`')
      pattern='public struct WebSocketPongContext'
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
    '`WebSocketCloseCode`')
      pattern='public enum WebSocketCloseCode'
      target="$repo_root/Sources/InnoNetworkWebSocket/WebSocketCloseCode.swift"
      ;;
    *)
      fail "unknown stable symbol mapping: $symbol"
      ;;
  esac

  if has_rg; then
    if [[ "$symbol" == '`NetworkClient.request(_:)`' || "$symbol" == '`NetworkClient.upload(_:)`' ]]; then
      validate_protocol_symbol "NetworkClient" "$target" "$pattern"
    else
      rg -Fq "$pattern" "$target" || fail "stable symbol $symbol is not present in production sources"
    fi
  else
    if [[ "$symbol" == '`NetworkClient.request(_:)`' || "$symbol" == '`NetworkClient.upload(_:)`' ]]; then
      validate_protocol_symbol "NetworkClient" "$target" "$pattern"
    else
      grep -Fq "$pattern" "$target" || fail "stable symbol $symbol is not present in production sources"
    fi
  fi
done

for symbol in "${expected_provisionally[@]}"; do
  case "$symbol" in
    '`default` aliases on configuration types')
      validate_default_aliases
      continue
      ;;
    'benchmark runner CLI flags and JSON summary presentation details')
      validate_benchmark_docs
      continue
      ;;
    'troubleshooting guidance and examples in README/DocC')
      validate_troubleshooting_and_examples_docs
      continue
      ;;
    '`InnoNetworkTestSupport` library product and its `public` symbols')
      validate_test_support_product
      continue
      ;;
    '`Endpoint`, `AnyEncodable`, `NetworkContext`, and `CorrelationIDInterceptor`')
      validate_oss_readiness_public_api
      continue
      ;;
    *)
      fail "unknown provisionally stable symbol mapping: $symbol"
      ;;
  esac
done

validate_public_surface_ledger

require_contains "API Stability" "$readme"
require_contains ".safeDefaults(" "$readme"
require_contains "CONTRIBUTING.md" "$readme"
require_contains "SECURITY.md" "$readme"
require_contains "SUPPORT.md" "$readme"
require_contains "docs/RELEASE_POLICY.md" "$readme"

for doc in "${required_meta_docs[@]}"; do
  [[ -f "$doc" ]] || fail "required OSS document is missing: $doc"
done

for doc in "${required_feature_docs[@]}"; do
  [[ -f "$doc" ]] || fail "required feature documentation file is missing: $doc"
done

for doc in "${example_docs[@]}"; do
  [[ -f "$doc" ]] || fail "example documentation file is missing: $doc"
  require_contains "safeDefaults" "$doc"
done

forbidden_pattern 'configuration:\s*NetworkConfiguration\(' "$readme" "${example_docs[@]}"
forbidden_pattern 'let configuration = NetworkConfiguration\(' "$readme" "${example_docs[@]}"
forbidden_pattern 'let client = DefaultNetworkClient\(\s*configuration:\s*\.default' "$readme" "${example_docs[@]}"
forbidden_pattern 'addText|addFile' "$readme" "${example_docs[@]}"
forbidden_pattern 'from:\s*"1\.0\.0"' "$readme" "${example_docs[@]}"

echo "docs-contract-sync: OK"
