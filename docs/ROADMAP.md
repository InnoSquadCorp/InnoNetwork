# Roadmap

## Deferred Operational Follow-ups

- persistence 내구성 심화: `fsync`, `checksum`, `compaction budget`, 대용량 큐 기준 정립
- websocket 확장 포인트: handshake/auth refresh와 app-level protocol failure 분리
- benchmark governance 확장: threshold 도입, trend tracking, PR comment 자동화
- configuration API 장기 정리: advanced surface 축소와 권장 public path 단순화
- `@unchecked Sendable` 제거 로드맵: 현재 승인된 6개 예외(`EventPipelineMetricsReporterProxy`, `URLQueryEncoder`, `QueryValueBox`, `SnakeCaseKeyTransformCache`, `_URLQueryValueEncoder`, `URLQueryCustomKeyTransform`)를 단계적으로 제거하고, 필요 시 public API와 내부 동시성 모델을 재설계

## Public DSL Candidate

- 현재 `RequestEncodingPolicy`, `ResponseDecodingStrategy`, `TransportPolicy`는 내부 설계 축으로 유지합니다.
- 다음 마일스톤에서 public DSL 승격 여부를 다시 판단합니다.
