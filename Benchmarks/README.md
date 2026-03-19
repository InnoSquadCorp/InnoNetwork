# Benchmark Governance

`InnoNetworkBenchmarks`는 라이브러리의 핵심 hot path를 빠르게 비교하기 위한 내부 benchmark runner입니다.

## Covered Benchmarks

- `encoding/query-encoder-*`
- `events/task-event-*`
- `persistence/append-log-*`
- `websocket/websocket-reconnect-decision`

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
- runner는 baseline 대비 diff를 출력하지만 현재 단계에서는 실패시키지 않습니다.
- baseline은 의미 있는 성능 변화가 확인된 경우에만 사람이 갱신합니다.
- baseline 자동 업데이트는 하지 않습니다.

## CI Policy

- 기본 CI는 benchmark target의 build smoke만 수행합니다.
- 실제 benchmark 실행은 수동 또는 scheduled benchmark workflow에서만 수행합니다.
- workflow는 JSON summary artifact를 업로드합니다.
