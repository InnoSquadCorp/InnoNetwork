# Roadmap

## Deferred Operational Follow-ups

- persistence 내구성 심화: `fsync`, `checksum`, `compaction budget`, 대용량 큐 기준 정립
- websocket 확장 포인트: handshake/auth refresh와 app-level protocol failure 분리
- benchmark governance 확장: threshold 도입, trend tracking, PR comment 자동화
- configuration API 장기 정리: advanced surface 축소와 권장 public path 단순화
- `@unchecked Sendable` 제거 로드맵: 현재 승인된 6개 예외(`EventPipelineMetricsReporterProxy`, `URLQueryEncoder`, `QueryValueBox`, `SnakeCaseKeyTransformCache`, `_URLQueryValueEncoder`, `URLQueryCustomKeyTransform`)를 단계적으로 제거하고, 필요 시 public API와 내부 동시성 모델을 재설계
- `DownloadManager` actor 전환: 현재 `final class : NSObject, Sendable` 형태로 mutable state 가 actor 3종(`DownloadRuntimeRegistry`, `DownloadTaskPersistence`, `BackgroundCompletionStore`)에 분산되어 보호됨. 호출부 영향 반경(약 12개 테스트 파일 + Examples)을 고려해 별도 PR 로 분리. 본 epic 의 4.1 라인에서는 isolation contract 문서화만 반영.
- Append-log persistence 비동기화: 현재 `flock` + sync write 흐름을 `Task.detached(priority:.utility)` 백프레셔 큐로 이동, `fsync` 정책 노출(`DownloadConfiguration.persistenceFsyncPolicy: .always | .onCheckpoint | .never`). `DownloadManager` actor 전환 PR 의 후속으로 진행.

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
