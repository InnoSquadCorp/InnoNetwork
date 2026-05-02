#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"
export LC_ALL=C

api_stability="$repo_root/API_STABILITY.md"
readme="$repo_root/README.md"
public_symbols_allowlist="$repo_root/Scripts/api_public_symbols.allowlist"
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
  "$repo_root/Sources/InnoNetwork/InnoNetwork.docc/Articles/OpenAPIGeneratorAdapter.md"
  "$repo_root/Sources/InnoNetwork/InnoNetwork.docc/Articles/AuthRefresh.md"
  "$repo_root/Sources/InnoNetwork/InnoNetwork.docc/Articles/CachingStrategies.md"
  "$repo_root/Sources/InnoNetwork/InnoNetwork.docc/Articles/UsingMacros.md"
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
'`CancellationTag`'
'`EndpointShape`'
'`MultipartAPIDefinition`'
'`TransportPolicy`'
'`RequestEncodingPolicy`'
'`ResponseDecodingStrategy`'
'`DefaultNetworkClient`'
'`NetworkClient.request(_:)`'
'`NetworkClient.request(_:tag:)`'
'`NetworkClient.upload(_:)`'
'`NetworkClient.upload(_:tag:)`'
'`NetworkConfiguration.safeDefaults(baseURL:)`'
'`NetworkConfiguration.advanced(baseURL:_:)`'
'`DownloadConfiguration.safeDefaults()`'
'`DownloadConfiguration.advanced(_:)`'
'`WebSocketConfiguration.safeDefaults()`'
'`WebSocketConfiguration.advanced(_:)`'
'`WebSocketHandshakeRequestAdapter`'
'`DownloadManager`'
'`WebSocketManager`'
'`WebSocketEvent.ping`'
'`WebSocketEvent.pong`'
'`WebSocketEvent.error(.pingTimeout)`'
'`WebSocketPingContext`'
'`WebSocketPongContext`'
'`TrustPolicy`'
'`PublicKeyPinningPolicy`'
'`PublicKeyPinningPolicy.HostMatchingStrategy`'
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
'`Endpoint`, `EndpointPathEncoding`, `AnyEncodable`, `NetworkContext`, and `CorrelationIDInterceptor`'
'`WebSocketCloseDisposition` observation surface'
'`RefreshTokenPolicy`, `RequestCoalescingPolicy`, response cache, and circuit breaker policy surfaces'
'`MultipartResponseDecoder` buffered multipart response parsing surface'
'`InnoNetworkCodegen` separate package and macro declarations'
'`DecodingInterceptor`'
)

expected_shipping_public_declarations=(
  APIDefinition
  AnyEncodable
  AnyResponseDecoder
  CachedResponse
  CancellationTag
  CircuitBreakerOpenError
  CircuitBreakerPolicy
  ContentType
  CorrelationIDInterceptor
  DecodingInterceptor
  DecodingStage
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
  EndpointPathEncoding
  EndpointShape
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
  InMemoryResponseCache
  MultipartAPIDefinition
  MultipartFormData
  MultipartPart
  MultipartResponseDecoder
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
  RefreshTokenPolicy
  RequestCoalescingPolicy
  RequestEncodingPolicy
  RequestInterceptor
  Response
  ResponseCache
  ResponseCacheKey
  ResponseCachePolicy
  ResponseDecodingStrategy
  ResponseInterceptor
  RetryDecision
  RetryIdempotencyPolicy
  RetryPolicy
  SendableUnderlyingError
  ServerSentEvent
  ServerSentEventDecoder
  StreamingAPIDefinition
  StreamingResumePolicy
  TimeoutReason
  TransportPolicy
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
  WebSocketHandshakeRequestAdapter
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
  MockURLSession
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
  require_contains 'public final class MockURLSession' \
    "$repo_root/Sources/InnoNetworkTestSupport/MockURLSession.swift"
}

validate_resilience_public_api() {
  require_contains 'public struct RefreshTokenPolicy' \
    "$repo_root/Sources/InnoNetwork/Auth/RefreshTokenPolicy.swift"
  require_contains 'public struct RequestCoalescingPolicy' \
    "$repo_root/Sources/InnoNetwork/RequestCoalescing/RequestCoalescingPolicy.swift"
  require_contains 'public enum ResponseCachePolicy' \
    "$repo_root/Sources/InnoNetwork/Cache/ResponseCachePolicy.swift"
  require_contains 'public protocol ResponseCache' \
    "$repo_root/Sources/InnoNetwork/Cache/ResponseCachePolicy.swift"
  require_contains 'public actor InMemoryResponseCache' \
    "$repo_root/Sources/InnoNetwork/Cache/ResponseCachePolicy.swift"
  require_contains 'public struct CircuitBreakerPolicy' \
    "$repo_root/Sources/InnoNetwork/CircuitBreaker/CircuitBreakerPolicy.swift"
  require_contains 'public struct CircuitBreakerOpenError' \
    "$repo_root/Sources/InnoNetwork/CircuitBreaker/CircuitBreakerPolicy.swift"
  require_contains 'refreshTokenPolicy: RefreshTokenPolicy? = nil' \
    "$repo_root/Sources/InnoNetwork/NetworkConfiguration.swift"
  require_contains 'requestCoalescingPolicy: RequestCoalescingPolicy = .disabled' \
    "$repo_root/Sources/InnoNetwork/NetworkConfiguration.swift"
  require_contains 'responseCachePolicy: ResponseCachePolicy = .disabled' \
    "$repo_root/Sources/InnoNetwork/NetworkConfiguration.swift"
  require_contains 'circuitBreakerPolicy: CircuitBreakerPolicy? = nil' \
    "$repo_root/Sources/InnoNetwork/NetworkConfiguration.swift"
}

validate_multipart_response_api() {
  require_contains 'public struct MultipartPart' \
    "$repo_root/Sources/InnoNetwork/Multipart/MultipartResponseDecoder.swift"
  require_contains 'public struct MultipartResponseDecoder' \
    "$repo_root/Sources/InnoNetwork/Multipart/MultipartResponseDecoder.swift"
}

validate_codegen_product() {
  local codegen_package="$repo_root/Packages/InnoNetworkCodegen/Package.swift"
  local codegen_macros="$repo_root/Packages/InnoNetworkCodegen/Sources/InnoNetworkCodegen/Macros.swift"
  require_contains 'dependencies: []' "$repo_root/Package.swift"
  require_contains 'name: "InnoNetworkCodegen"' "$codegen_package"
  require_contains 'targets: ["InnoNetworkCodegen"]' "$codegen_package"
  require_contains 'name: "InnoNetworkMacros"' "$codegen_package"
  require_contains 'https://github.com/swiftlang/swift-syntax.git' "$codegen_package"
  require_contains 'from: "603.0.1"' "$codegen_package"
  require_contains 'public macro APIDefinition' "$codegen_macros"
  require_contains 'public macro endpoint' "$codegen_macros"
  require_contains '`APIDefinition(method:path:)`' "$api_stability"
  require_contains '`endpoint(_:_:as:)`' "$api_stability"
}

collect_public_symbols() {
  command -v python3 > /dev/null 2>&1 || fail "python3 is required for symbol graph public surface validation"

  find "$repo_root/.build" -path '*/symbolgraph/*.symbols.json' -type f -delete 2> /dev/null || true

  local dump_status
  set +e
  swift package dump-symbol-graph \
    --minimum-access-level public \
    --include-spi-symbols \
    --skip-synthesized-members > /dev/null
  dump_status=$?
  set -e

  python3 - "$repo_root" <<'PY'
import json
import sys
from pathlib import Path

repo_root = Path(sys.argv[1])
symbolgraph_dirs = [path for path in (repo_root / ".build").glob("*/symbolgraph") if path.is_dir()]
if not symbolgraph_dirs:
    raise SystemExit("No Swift symbol graph directory was generated.")

symbolgraph_dir = max(symbolgraph_dirs, key=lambda path: path.stat().st_mtime)
included_modules = {
    "InnoNetwork",
    "InnoNetworkDownload",
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
rows = set()
seen_modules = set()
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
PY

  if [[ "$dump_status" -ne 0 ]]; then
    echo "docs-contract-sync: swift package dump-symbol-graph exited with $dump_status after emitting required library symbol graphs; ignoring non-contract target extraction failure." >&2
  fi
}

validate_public_surface_ledger() {
  [[ -f "$public_symbols_allowlist" ]] || fail "public symbol allowlist is missing: $public_symbols_allowlist"
  require_line $'InnoNetwork\tswift.struct\tNetworkConfiguration.AdvancedBuilder' "$public_symbols_allowlist"
  require_line $'InnoNetwork\tswift.property\tNetworkConfiguration.AdvancedBuilder.requestInterceptors' "$public_symbols_allowlist"

  local expected_file
  local actual_file
  expected_file="$(mktemp)"
  actual_file="$(mktemp)"

  awk 'NF && $0 !~ /^#/ { print }' "$public_symbols_allowlist" | sort -u > "$expected_file"
  collect_public_symbols > "$actual_file"

  if ! diff -u "$expected_file" "$actual_file" >&2; then
    fail "public symbol graph drifted; update Scripts/api_public_symbols.allowlist and API_STABILITY.md"
  fi

  rm -f "$expected_file" "$actual_file"

  for declaration in "${expected_shipping_public_declarations[@]}" "${expected_spi_public_declarations[@]}" \
    "${expected_test_support_public_declarations[@]}"; do
    require_contains "\`$declaration\`" "$api_stability"
  done
}

validate_oss_readiness_public_api() {
  require_contains 'public struct Endpoint<Response: Decodable & Sendable>: APIDefinition' \
    "$repo_root/Sources/InnoNetwork/Endpoint.swift"
  require_contains 'public enum EndpointPathEncoding' \
    "$repo_root/Sources/InnoNetwork/EndpointPathEncoding.swift"
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
  require_contains 'Release Notes: [docs/releases/4.0.0.md](docs/releases/4.0.0.md)' "$readme"
  require_contains '### 1. [BasicRequest](./BasicRequest)' "$repo_root/Examples/README.md"
  require_contains '### 2. [ErrorHandling](./ErrorHandling)' "$repo_root/Examples/README.md"
  require_contains '### 3. [CustomHeaders](./CustomHeaders)' "$repo_root/Examples/README.md"
  require_contains '### 4. [RealWorldAPI](./RealWorldAPI)' "$repo_root/Examples/README.md"
  require_contains '### [ConsumerSmoke](./ConsumerSmoke)' "$repo_root/Examples/README.md"
  require_contains '### [CoreSmoke](./CoreSmoke)' "$repo_root/Examples/README.md"
  require_contains '### [TestSupportSmoke](./TestSupportSmoke)' "$repo_root/Examples/README.md"
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
    '`CancellationTag`')
      pattern='public struct CancellationTag'
      target="$repo_root/Sources/InnoNetwork/CancellationTag.swift"
      ;;
    '`EndpointShape`')
      pattern='public protocol EndpointShape: Sendable'
      target="$repo_root/Sources/InnoNetwork/EndpointShape.swift"
      ;;
    '`MultipartAPIDefinition`')
      pattern='public protocol MultipartAPIDefinition'
      target="$repo_root/Sources/InnoNetwork/APIDefinition.swift"
      ;;
    '`TransportPolicy`')
      pattern='public struct TransportPolicy'
      target="$repo_root/Sources/InnoNetwork/TransportPolicy.swift"
      ;;
    '`RequestEncodingPolicy`')
      pattern='public enum RequestEncodingPolicy'
      target="$repo_root/Sources/InnoNetwork/RequestEncodingPolicy.swift"
      ;;
    '`ResponseDecodingStrategy`')
      pattern='public enum ResponseDecodingStrategy'
      target="$repo_root/Sources/InnoNetwork/ResponseDecodingStrategy.swift"
      ;;
    '`DefaultNetworkClient`')
      pattern='public final class DefaultNetworkClient'
      target="$repo_root/Sources/InnoNetwork/DefaultNetworkClient.swift"
      ;;
    '`NetworkClient.request(_:)`')
      pattern='^    func request<T: APIDefinition>\(_ request: T\) async throws -> T\.APIResponse$'
      target="$repo_root/Sources/InnoNetwork/DefaultNetworkClient.swift"
      ;;
    '`NetworkClient.request(_:tag:)`')
      pattern='^    func request<T: APIDefinition>\(_ request: T, tag: CancellationTag\?\) async throws -> T\.APIResponse$'
      target="$repo_root/Sources/InnoNetwork/DefaultNetworkClient.swift"
      ;;
    '`NetworkClient.upload(_:)`')
      pattern='^    func upload<T: MultipartAPIDefinition>\(_ request: T\) async throws -> T\.APIResponse$'
      target="$repo_root/Sources/InnoNetwork/DefaultNetworkClient.swift"
      ;;
    '`NetworkClient.upload(_:tag:)`')
      pattern='^    func upload<T: MultipartAPIDefinition>\(_ request: T, tag: CancellationTag\?\) async throws -> T\.APIResponse$'
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
    '`WebSocketHandshakeRequestAdapter`')
      pattern='public struct WebSocketHandshakeRequestAdapter'
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
    '`PublicKeyPinningPolicy`')
      pattern='public struct PublicKeyPinningPolicy'
      target="$repo_root/Sources/InnoNetwork/TrustPolicy.swift"
      ;;
    '`PublicKeyPinningPolicy.HostMatchingStrategy`')
      pattern='public enum HostMatchingStrategy: Sendable, Equatable'
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

  case "$symbol" in
    '`NetworkClient.request(_:)`' | '`NetworkClient.request(_:tag:)`' | '`NetworkClient.upload(_:)`' | '`NetworkClient.upload(_:tag:)`')
      validate_protocol_symbol "NetworkClient" "$target" "$pattern"
      ;;
    *)
      if has_rg; then
        rg -Fq "$pattern" "$target" || fail "stable symbol $symbol is not present in production sources"
      else
        grep -Fq "$pattern" "$target" || fail "stable symbol $symbol is not present in production sources"
      fi
      ;;
  esac
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
    '`Endpoint`, `EndpointPathEncoding`, `AnyEncodable`, `NetworkContext`, and `CorrelationIDInterceptor`')
      validate_oss_readiness_public_api
      continue
      ;;
    '`WebSocketCloseDisposition` observation surface')
      require_contains 'public enum WebSocketCloseDisposition: Sendable, Equatable' \
        "$repo_root/Sources/InnoNetworkWebSocket/WebSocketCloseDisposition.swift"
      continue
      ;;
    '`RefreshTokenPolicy`, `RequestCoalescingPolicy`, response cache, and circuit breaker policy surfaces')
      validate_resilience_public_api
      continue
      ;;
    '`MultipartResponseDecoder` buffered multipart response parsing surface')
      validate_multipart_response_api
      continue
      ;;
    '`InnoNetworkCodegen` separate package and macro declarations')
      validate_codegen_product
      continue
      ;;
    '`DecodingInterceptor`')
      require_contains 'public protocol DecodingInterceptor' \
        "$repo_root/Sources/InnoNetwork/DecodingInterceptor.swift"
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
forbidden_pattern 'Xcode 15|Xcode 16' "$readme" "${example_docs[@]}" "$repo_root/docs" "$repo_root/Sources"
forbidden_pattern 'does not pull|do not pull|not pull `swift-syntax`|has no external dependencies|no external dependencies;' \
  "$api_stability" \
  "$readme" \
  "$repo_root/CHANGELOG.md" \
  "$repo_root/docs/releases/4.0.0.md" \
  "$repo_root/SECURITY.md" \
  "$repo_root/docs" \
  "$repo_root/Sources"
forbidden_pattern '4\.2\.0|4\.2 line|pre-v4\.2|v4\.2|docs/releases/4\.2\.0' \
  "$api_stability" \
  "$readme" \
  "$repo_root/CHANGELOG.md" \
  "$repo_root/docs/releases/4.0.0.md" \
  "$repo_root/SECURITY.md" \
  "$repo_root/Benchmarks/README.md" \
  "$repo_root/docs" \
  "$repo_root/Sources" \
  "$repo_root/Tests"
forbidden_pattern 'public func receive\(_ task: WebSocketTask\)' \
  "$repo_root/Sources/InnoNetworkWebSocket"
forbidden_pattern 'manager\.receive\(' \
  "$repo_root/README.md" \
  "$repo_root/CHANGELOG.md" \
  "$repo_root/docs" \
  "$repo_root/Sources" \
  "$repo_root/Tests"

require_contains 'GET responses with RFC-cacheable whole-response status codes' \
  "$repo_root/Sources/InnoNetwork/InnoNetwork.docc/Articles/CachingStrategies.md"
require_contains '`Cache-Control: no-store` responses are not stored' \
  "$repo_root/Sources/InnoNetwork/InnoNetwork.docc/Articles/CachingStrategies.md"
require_contains 'The response `Vary` header is processed automatically' \
  "$repo_root/Sources/InnoNetwork/InnoNetwork.docc/Articles/CachingStrategies.md"
forbidden_pattern 'Only `200 OK` responses are persisted|written back on a 200 response|does not implement full HTTP `Vary`|server `Cache-Control: no-store` are not honoured|응답 `Vary` 헤더 기반 자동 key 확장은 별도 설계가 필요하다|Cache-Control expansion' \
  "$repo_root/README.md" \
  "$repo_root/docs" \
  "$repo_root/Sources/InnoNetwork" \
  "$repo_root/Sources/InnoNetwork/InnoNetwork.docc"

echo "docs-contract-sync: OK"
