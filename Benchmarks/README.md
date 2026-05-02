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
      "operationsPerSecond": 82034.8750762668
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
