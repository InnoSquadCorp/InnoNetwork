# 오류 처리

``NetworkError`` case 를 사용자 회복 흐름으로 매핑하면서 원래의 구조화된
컨텍스트를 잃지 않게 처리하는 방법을 설명합니다.

> 한국어 번역본 (영문 원본 → <doc:ErrorClassification>) 입니다. 두 문서의
> 내용이 일치하지 않을 때는 영문 원본의 정의를 우선합니다.

## 개요

`NetworkError` 는 transport 실패에 대해 명시적으로 case 가 나뉘어 있습니다.
단일 문자열 오류와 달리 각 case 는 재시도할지, 사용자에게 노출할지,
크래시 리포팅으로 escalate 할지 결정하는 데 필요한 구조화된 정보를 직접
들고 있습니다.

## case 한눈에 보기

| Case | 원인 | 일반적인 회복 |
|------|------|----------------|
| ``NetworkError/configuration(reason:)`` 의 ``NetworkConfigurationFailureReason/invalidBaseURL(_:)`` | 클라이언트 설정 오류. | 프로그래머 오류로 간주. DEBUG 빌드에서 assert. |
| ``NetworkError/configuration(reason:)`` 의 ``NetworkConfigurationFailureReason/invalidRequest(_:)`` | 요청 모양과 정책 불일치. | API 정의를 수정. 재시도 금지. |
| ``NetworkError/configuration(reason:)`` 의 ``NetworkConfigurationFailureReason/offline(_:)`` | reachability 정책이 오프라인을 감지. | 오프라인 UI 노출 또는 비대화형 작업을 지연. |
| ``NetworkError/statusCode(_:)`` | 서버가 비허용 status code 반환. | `.response.statusCode` 로 분기. 재시도는 `RetryPolicy` 가 결정. |
| ``NetworkError/decoding(stage:underlying:response:)`` | 파이프라인의 특정 단계에서 디코딩 실패 (`.responseBody` 또는 `.streamFrame`). | 사용자에게 노출하고 엔드포인트 feature flag 적용 검토. 디코딩 실패는 terminal 이며 `isDecodingFailure` 가 커스텀 재시도 정책에서 명시적으로 노출됩니다. |
| ``NetworkError/reachability(_:_:_:)`` | `URLError` 에서 분류된 DNS, 오프라인, 연결 끊김. | 네트워크 reachability 로 처리. 요청이 안전하고 정책 예산이 허용하면 재시도. |
| ``NetworkError/underlying(_:)`` | 위 분류에 속하지 않는 Foundation/URLSession 오류 (드물게 비-HTTPURLResponse 경로도 코드 `3002` 로 래핑됨). | `SendableUnderlyingError.code` 로 더 깊은 triage. |
| ``NetworkError/trustEvaluationFailed(_:)`` | TLS pinning 또는 사용자 정의 신뢰 평가기가 인증서 체인 거부. | 사용자에게 노출. 자동 재시도 금지. |
| ``NetworkError/cancelled`` | `Task` 취소 또는 `cancelAll()`. | 조용히 존중. 호출부의 의도된 중단. |
| ``NetworkError/timeout(_:)`` | 요청/리소스/연결 타임아웃. | 예산이 허용하면 재시도. |

## 레시피: 코드가 아닌 분류로 분기

```swift
do {
    let user = try await client.request(GetUser())
    return .success(user)
} catch {
    switch error {
    case .cancelled:
        return .cancelled

    case .timeout:
        return .recoverableNetwork

    case .reachability(.notConnectedToInternet, _, _):
        return .offline

    case .statusCode(let response) where (500...599).contains(response.statusCode):
        return .recoverableServer

    case .statusCode(let response) where response.statusCode == 401:
        return .reauthenticate

    case .configuration(reason: .offline):
        return .offline

    case .trustEvaluationFailed:
        return .securityFailure  // 자동 재시도 금지

    @unknown default:
        return .failure(error)
    }
}
```

`NetworkError` 는 `@frozen` 이 아니므로 마이너 릴리스에서 새 case 가 추가될
수 있습니다. exhaustive switch 의 끝에는 항상 `@unknown default` 를 두어
컴파일이 깨지지 않도록 하세요. 핵심은 **case + 구조화된 페이로드**로
분기하고, 문자열 비교에 의존하지 않는 것입니다. 호출 지점에서 두 화면 떨어진
코드도 라이브러리 변경에 안정적으로 견딥니다.

## 실패 페이로드 캡처

`NetworkError.decoding(stage:underlying:response:)` 는 실패한 디코딩의 `Response`
를 함께 들고 옵니다. 기본 동작은 오류가 노출되기 전에 `response.data` 를 빈
Data 로 redact 하는 것입니다.

원본 응답 본문은 `NetworkConfiguration.captureFailurePayload = true` 로 명시
opt-in 한 경우에만 보존됩니다. 프로덕션에서는 PII 가 크래시 리포트, 분석,
로그에 유출되지 않도록 이 플래그를 꺼 두세요.

## NSError 브리지

`NetworkError` 는 안정 도메인 `com.innosquad.innonetwork` 로 NSError 브리지가
됩니다. 4.x 라인은 숫자 코드를 안정적으로 유지하므로, 관측 가능성 파이프라인이
지역화 문자열을 파싱하지 않고도 실패를 그룹화할 수 있습니다. 기저 Foundation
오류는 `.underlying` / timeout case 안에 ``SendableUnderlyingError`` 로
보존되며, status code 실패는 구조화된 ``Response`` 메타데이터를 유지합니다.

## cancellation 은 실패가 아닙니다

`NetworkError.cancelled` 는 종결되지만 *예상된* 유일한 결과입니다. 분석이나
크래시 로그에 오류로 보고하지 마세요 — 사용자 주도 취소, 로그아웃 정리,
`cancelAll()` 의 계약입니다.

InnoNetwork 의 모든 product 에서 cancellation 은 terminal 이며 재시도되지
않습니다.

- 일반 요청, 업로드, 스트림: ``NetworkError/cancelled`` 노출
- stale-while-revalidate 백그라운드 취소: 호출부가 이미 캐시 값을 받았으므로
  조용히 무시
- 다운로드: `DownloadState.cancelled` 로 전이하고 state 이벤트 발행
- 웹소켓: `WebSocketState.cancelled` 로 전이하고 observer 가 부착된 경우
  cancellation 오류 이벤트 발행

## 관련 항목

- ``NetworkError``
- ``SendableUnderlyingError``
- <doc:ErrorClassification>
