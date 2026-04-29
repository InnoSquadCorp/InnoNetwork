# Benchmark Governance

`InnoNetworkBenchmarks`는 라이브러리의 핵심 hot path를 빠르게 비교하기 위한 내부 benchmark runner입니다.

## Covered Benchmarks

- `encoding/query-encoder-*` — `URLQueryEncoder` hot path (snake-case 변환 포함).
- `events/task-event-*` — `TaskEventHub` fan-out / slow listener isolation.
- `persistence/append-log-*` — Download persistence append/replay/compaction.
- `websocket/websocket-reconnect-decision` — `WebSocketReconnectCoordinator.reconnectAction` 분기 비용.
- `websocket/websocket-close-disposition-classify` — `WebSocketCloseDisposition.classifyPeerClose` 분류기 비용 (4.0.0).
- `websocket/websocket-ping-context-alloc` — `WebSocketPingContext` 생성 + `ContinuousClock.now` 읽기 비용 (4.0.0, heartbeat 루프 핫패스).

## Output Schema

Runner는 human-readable summary와 JSON summary를 모두 출력합니다. JSON은 다음 형식으로 고정합니다.

```json
{
  "version": 1,
  "generatedAt": "2026-03-19T05:35:45Z",
  "results": [
    {
      "name": "query-encoder-small",
      "group": "encoding",
      "iterations": 2000,
      "elapsedSeconds": 0.024379875,
      "operationsPerSecond": 82034.8750762668
    }
  ]
}
```

## Baseline Policy

- baseline 파일은 [Baselines/default.json](Baselines/default.json)입니다.
- runner는 baseline 대비 diff를 항상 출력합니다.
- `--enforce-baseline`를 주면 guarded benchmark가 지정 threshold보다 느려질 때 non-zero exit로 실패합니다.
- `--guard-benchmark group/name`는 회귀 판정 대상을 고정합니다. 지정하지 않으면 현재 실행된 전체 benchmark를 검사합니다.
- `--max-regression-percent <Double>`는 허용 가능한 최대 성능 저하 폭을 정합니다.
- baseline은 의미 있는 성능 변화가 확인된 경우에만 사람이 갱신합니다.
- baseline 자동 업데이트는 하지 않습니다.

## CI Policy

- PR CI는 `--quick` benchmark를 실제 실행하되, websocket guard 2개만 `20%` threshold로 막는 smoke gate를 사용합니다.
- scheduled/manual benchmark workflow는 같은 websocket guard 2개를 `10%` threshold로 검사하는 strict regression gate입니다.
- 두 workflow 모두 JSON summary artifact를 업로드해 실패 시 수치 비교를 바로 확인할 수 있게 합니다.
