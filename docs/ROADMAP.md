# Roadmap

## Deferred Operational Follow-ups

- persistence 내구성 심화: `fsync`, `checksum`, `compaction budget`, 대용량 큐 기준 정립
- websocket 확장 포인트: handshake/auth refresh와 app-level protocol failure 분리
- benchmark governance 확장: threshold 도입, trend tracking, PR comment 자동화
- configuration API 장기 정리: advanced surface 축소와 권장 public path 단순화
- `@unchecked Sendable` 제거 로드맵: 현재 승인된 6개 예외(`EventPipelineMetricsReporterProxy`, `URLQueryEncoder`, `QueryValueBox`, `SnakeCaseKeyTransformCache`, `_URLQueryValueEncoder`, `URLQueryCustomKeyTransform`)를 단계적으로 제거하고, 필요 시 public API와 내부 동시성 모델을 재설계
- 벤치마크 baseline refresh: `Benchmarks/Baselines/default.json` 은 v4.1 작업 (특히 `WebSocketTask` send-slot 도입, `DownloadManager` actor 전환, `persistenceFsyncPolicy` 도입) 이전에 기록되어 현재 CI 의 `--max-regression-percent` 를 50% 이하로 좁히면 false-positive 가 발생. v4.1 출시 시점에 macos-15 runner 에서 baseline 을 재생성하고 threshold 를 10% 로 점진 조임.
- WebSocket `permessage-deflate` (RFC 7692): `URLSessionWebSocketTask` 가 deflate 협상을 노출하지 않아 transport substitution 필요. 선택지: (a) `InnoNetworkWebSocketNIO` 새 product (swift-nio 의존), (b) `Network.framework` 직접 구현. v5 라인에서 선택 결정.

## Post-4.0 Candidates

- Low-level execution hooks for generated clients and wrapper frameworks.
- Public close-disposition observation for WebSocket lifecycle UX.
- Ping/pong context payloads with library-computed round-trip timing.
- Download retry backoff tuning with jitter and explicit caps.
- Runnable WebSocket / Download / event-policy observer samples.
- ThreadSanitizer and stricter benchmark regression gates.

## Public DSL Candidate

- 현재 `RequestEncodingPolicy`, `ResponseDecodingStrategy`, `TransportPolicy`는 내부 설계 축으로 유지합니다.
- 다음 마일스톤에서 public DSL 승격 여부를 다시 판단합니다.
