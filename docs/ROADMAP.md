# Roadmap

## Deferred Operational Follow-ups

- persistence 내구성 심화: `fsync`, `checksum`, `compaction budget`, 대용량 큐 기준 정립
- websocket 확장 포인트: handshake/auth refresh와 app-level protocol failure 분리
- benchmark governance 확장: threshold 도입, trend tracking, PR comment 자동화
- configuration API 장기 정리: advanced surface 축소와 권장 public path 단순화
- `@unchecked Sendable` 회귀 방지: production source는 CI에서 금지하고, 테스트 전용 helper의 예외는 TestSupport/test target 안에만 둔다.
- 벤치마크 trend tracking: `Benchmarks/Baselines/default.json` 은 macos-15 기준으로 갱신되었고, PR smoke는 20%, scheduled/manual workflow는 10% threshold를 사용한다. 다음 단계는 PR comment 자동화와 장기 trend 저장소다.
- WebSocket `permessage-deflate` (RFC 7692): `URLSessionWebSocketTask` 가 deflate 협상을 노출하지 않아 transport substitution 필요. v5 후보는 optional `InnoNetworkWebSocketNIO` product (swift-nio 의존) 방향으로 둔다. 기존 URLSession 기반 4.0.0 product 안정성을 흔들지 않기 위해 `Network.framework` 직접 구현은 보조 조사 경로로 유지한다.
- Pulse adapter 예제: 4.0.0 범위에서는 macro/codegen과 resilience surface에 집중하고, 외부 observability dependency 예제는 별도 PR에서 평가한다.
- streaming multipart decoder: 4.0.0의 `MultipartResponseDecoder`는 buffered parser로 제한한다. 대용량 multipart streaming은 back-pressure와 partial failure semantics를 정한 뒤 별도 설계한다.
- Hummingbird in-process integration test: 4.0.0에서는 기본 CI 결정성을 유지하고, server-side Swift dependency가 필요한 통합 테스트는 follow-up으로 둔다.

## Post-4.0 Candidates

- Low-level execution hooks for generated clients and wrapper frameworks.
- Dedicated OpenAPI Generator adapter package/product. 4.0.0 은
  `APIDefinition` wrapper recipe 를 공식 경로로 두고, SPI hook 은 stable
  contract 밖에 둔다.
- Public close-disposition observation for WebSocket lifecycle UX.
- Ping/pong context payloads with library-computed round-trip timing.
- Download retry backoff tuning with jitter and explicit caps.
- Runnable WebSocket / Download / event-policy observer samples.
- ThreadSanitizer and stricter benchmark regression gates.

## Public DSL Candidate

- 현재 `RequestEncodingPolicy`, `ResponseDecodingStrategy`, `TransportPolicy`는 내부 설계 축으로 유지합니다.
- 다음 마일스톤에서 public DSL 승격 여부를 다시 판단합니다.
