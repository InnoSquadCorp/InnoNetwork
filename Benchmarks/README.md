# Benchmark Governance

`InnoNetworkBenchmarks`는 라이브러리의 핵심 hot path를 빠르게 비교하기 위한 내부 benchmark runner입니다.

## Covered Benchmarks

- `encoding/query-encoder-*` — `URLQueryEncoder` hot path (snake-case 변환 포함).
- `events/task-event-*` — `TaskEventHub` fan-out / slow listener isolation.
- `persistence/append-log-*` — Download persistence append/replay/compaction.
- `persistence/download-persistence-restore` — persisted download registry restore cost after app relaunch.
- `websocket/websocket-reconnect-decision` — `WebSocketReconnectCoordinator.reconnectAction` 분기 비용.
- `websocket/websocket-close-disposition-classify` — `WebSocketCloseDisposition.classifyPeerClose` 분류기 비용 (4.0.0).
- `websocket/websocket-ping-context-alloc` — `WebSocketPingContext` 생성 + `ContinuousClock.now` 읽기 비용 (4.0.0, heartbeat 루프 핫패스).
- `websocket/websocket-send-queue-reserve` — send queue backpressure slot 예약/해제 hot path.
- `websocket/websocket-lifecycle-transition-table` — lifecycle state transition table lookup cost.
- `client/request-pipeline` — in-memory `DefaultNetworkClient.request(_:)` dispatch/retry/event/decode path.
- `client/request-coalescing-shared-get` — shared GET request coalescing fan-in overhead.
- `client/decoding-interceptor-chain-{1,3,8}` — passive `DecodingInterceptor`
  chain depth baseline. The per-iteration delta between depths captures the
  per-link allocation/dispatch overhead. Baseline added so future
  regressions in the chain shape surface here before reaching production.
- `cache/response-cache-*` — response cache lookup and conditional revalidation preparation.

## Memory Metrics

각 benchmark는 throughput 외에 **resident memory 풋프린트**도 함께
보고합니다. `measure(name:group:iterations:work:)`가 클로저 실행 직전과
직후에 `mach_task_basic_info`를 호출해 다음 두 값을 캡처합니다.

- `peakResidentBytes`: 클로저 종료 직후 프로세스의 high-water resident
  set size (`resident_size_max`, bytes). 이 값은 프로세스 시작 이후의
  peak라서 앞서 실행된 benchmark의 영향을 포함할 수 있습니다.
- `residentDeltaBytes`: 클로저 종료 직후 현재 resident set size에서
  클로저 시작 직전 현재 resident set size를 뺀 값입니다. 양수는 클로저가
  새로 점유한 메모리, 음수는 시스템에 반환한 메모리입니다.

Resident 메모리는 페이지 단위(Apple Silicon은 16 KiB)로 반올림되므로,
같은 페이지 안에서 끝나는 작은 할당은 0으로 보일 수 있습니다.
이 지표는 **누수·과사용 시그널 감지용**이며 throughput 회귀 가드와 별도로
운영합니다 (4.0.0 기준 메모리 회귀 가드는 추가하지 않습니다 — 하드웨어/OS
사이의 페이지 정책 편차가 커 false positive 위험이 큽니다). 큰 변동이
관찰되면 Instruments Allocations 트레이스로 후속 분석하세요.

JSON 스키마에서 두 필드는 모두 `null`이 될 수 있고, 이전 baseline 리포트
(메모리 메트릭 도입 전)는 두 필드 모두 미포함이라도 그대로 디코드됩니다
(baseline 계약 backwards compatible).

## Output Schema

Runner는 human-readable summary와 JSON summary를 모두 출력합니다. JSON은 다음 형식으로 고정합니다.

```json
{
  "version": 2,
  "generatedAt": "2026-03-19T05:35:45Z",
  "results": [
    {
      "name": "query-encoder-small",
      "group": "encoding",
      "iterations": 2000,
      "elapsedSeconds": 0.024379875,
      "operationsPerSecond": 82034.8750762668,
      "peakResidentBytes": 214777856,
      "residentDeltaBytes": 1441792
    }
  ],
  "baseline": {
    "baselinePath": "Benchmarks/Baselines/default.json",
    "enforceBaseline": true,
    "maxRegressionPercent": 10,
    "deltas": [
      {
        "group": "encoding",
        "name": "query-encoder-small",
        "baselineOperationsPerSecond": 80000,
        "currentOperationsPerSecond": 82034.8750762668,
        "deltaPercent": 2.54,
        "isGuarded": false
      }
    ],
    "guardFailures": []
  }
}
```

## Baseline Policy

- baseline 파일은 [Baselines/default.json](Baselines/default.json)입니다.
- baseline 수치는 GitHub Actions `macos-15-arm64` hosted runner의 `--quick`
  결과를 기준으로 보정합니다. 로컬 개발 장비에서 더 빠르게 나오거나 느리게
  나오는 diff는 참고용입니다.
- runner는 baseline 대비 diff를 항상 출력합니다.
- `--enforce-baseline`를 주면 guarded benchmark가 지정 threshold보다 느려질 때 non-zero exit로 실패합니다.
- `--guard-benchmark group/name`는 회귀 판정 대상을 고정합니다. 지정하지 않으면 현재 실행된 전체 benchmark를 검사합니다.
- `--max-regression-percent <Double>`는 허용 가능한 최대 성능 저하 폭을 정합니다.
- baseline은 의미 있는 성능 변화가 확인된 경우에만 사람이 갱신합니다.
- baseline을 갱신하는 PR은 [Baselines/CHANGELOG.md](Baselines/CHANGELOG.md)에
  runner, 변경 이유, 검증 결과를 남깁니다.
- baseline 자동 업데이트는 하지 않습니다.

## Initial Baseline (4.0.0)

`decoding-interceptor-chain-{1,3,8}` baseline numbers from a single
`--quick` run on Apple Silicon (Darwin 25.4 / M-series). Local-only
reference; `Baselines/default.json` is the source of truth for CI.

| Benchmark | Iterations | Elapsed (s) | ops/sec |
| --- | --- | --- | --- |
| `client/decoding-interceptor-chain-1` | 2 000 | 0.0422 | ~47 400 |
| `client/decoding-interceptor-chain-3` | 2 000 | 0.0426 | ~46 900 |
| `client/decoding-interceptor-chain-8` | 2 000 | 0.0436 | ~45 900 |

The marginal cost of an additional passive interceptor is roughly
0.1 µs per request on this hardware, dominated by per-link async
function dispatch.

## CI Policy

- PR CI는 `--quick` benchmark를 실제 실행하고, 아래 guard 항목을 `20%` threshold로 막는 smoke gate를 사용합니다.
- `decoding-interceptor-chain-{1,3,8}` guard는 `--quick` smoke에서도
  20,000회 sample을 사용합니다. 2,000회 sample이 hosted runner에서 0.2초
  안팎으로 끝나 PR smoke가 scheduling noise에 과민해지는 것을 막기 위한
  안정화 설정입니다.
- PR benchmark workflow는 JSON summary에서 Markdown comment를 렌더링해 guarded
  benchmark delta를 PR에 남깁니다.
- scheduled/manual benchmark workflow는 같은 guard 항목을 `10%` threshold로 검사하는 strict regression gate입니다.
- scheduled/manual benchmark 결과는 `benchmark-trends` branch의
  `trends/benchmark-results.jsonl`에 누적됩니다.
- 두 workflow 모두 JSON summary artifact를 업로드해 실패 시 수치 비교를 바로 확인할 수 있게 합니다.

Guarded benchmark set:

- `events/task-event-fanout-single`: event delivery의 최소 fan-out baseline.
- `persistence/download-persistence-restore`: background download resume/restore 경로 baseline.
- `persistence/append-log-compaction`: append-log snapshot compaction 경로 baseline.
- `websocket/websocket-close-disposition-classify`: close callback마다 실행되는 분류 hot path.
- `websocket/websocket-ping-context-alloc`: heartbeat loop context 생성 hot path.
- `websocket/websocket-send-queue-reserve`: send queue backpressure accounting baseline.
- `websocket/websocket-lifecycle-transition-table`: lifecycle transition table lookup baseline.
- `client/request-pipeline`: core request pipeline overhead baseline.
- `client/request-coalescing-shared-get`: request coalescing fan-in baseline.
- `client/decoding-interceptor-chain-1`: single passive decoding interceptor overhead baseline.
- `client/decoding-interceptor-chain-3`: medium passive decoding interceptor chain overhead baseline.
- `client/decoding-interceptor-chain-8`: deeper passive decoding interceptor chain overhead baseline.
- `cache/response-cache-lookup`: cache hit lookup baseline.
- `cache/response-cache-revalidation`: conditional revalidation preparation baseline.
