# 오류 처리

``NetworkError`` case 를 사용자 회복 흐름으로 매핑하면서 원래의 구조화된
컨텍스트를 잃지 않게 처리하는 방법을 설명합니다.

> 한국어 번역본 (영문 원본 → <doc:ErrorClassification>) 입니다. 두 문서의
> 내용이 일치하지 않을 때는 영문 원본의 정의를 우선합니다.

## 개요

``NetworkError`` 는 라이브러리가 노출하는 유일한 오류 타입입니다.
`request(_:)`, `upload(_:)`, ``NetworkOperation/value()`` 가 이 타입을 던지고,
`stream(_:)` 시퀀스도 이 타입으로 실패합니다. 단일 문자열 오류와 달리 각 case 는
재시도할지, 사용자에게 노출할지, 크래시 리포팅으로 escalate 할지 결정하는 데
필요한 구조화된 정보를 직접 들고 있습니다.

대부분의 앱 계층 분기는 ``NetworkError/category``,
``NetworkError/isRetriableHint``, ``NetworkError/isUserVisible`` 로 시작하세요.
실패를 호출 지점 밖(view state, 분석, 로그)으로 내보낼 때는 payload 가 없는
``NetworkError/summary`` 를 사용합니다.

## case 한눈에 보기

| Case | 원인 | 일반적인 회복 |
|------|------|----------------|
| ``NetworkError/configuration(reason:)`` 의 ``NetworkConfigurationFailureReason/invalidBaseURL(_:)`` | 클라이언트 설정 오류. | 프로그래머 오류로 간주. DEBUG 빌드에서 assert. |
| ``NetworkError/configuration(reason:)`` 의 ``NetworkConfigurationFailureReason/invalidRequest(_:)`` | 요청 모양과 정책 불일치. | API 정의를 수정. 재시도 금지. |
| ``NetworkError/configuration(reason:)`` 의 ``NetworkConfigurationFailureReason/invalidPayload(_:)`` | binary 요청 codec 또는 byte 예산이 로컬 입력을 거부. | encoder 또는 예산을 수정. 재시도 금지. |
| ``NetworkError/configuration(reason:)`` 의 ``NetworkConfigurationFailureReason/offline(_:)`` | reachability 정책이 오프라인을 감지. | 오프라인 UI 노출 또는 비대화형 작업을 지연. |
| ``NetworkError/statusCode(_:)`` | 서버가 비허용 status code 반환. | `.response.statusCode` 로 분기. 재시도는 `RetryPolicy` 가 결정. |
| ``NetworkError/decoding(stage:underlying:response:)`` | 파이프라인의 특정 단계에서 디코딩 실패 (`.responseBody` 또는 `.streamFrame`). | 사용자에게 노출하고 엔드포인트 feature flag 적용 검토. 디코딩 실패는 terminal 이며 `isDecodingFailure` 가 커스텀 재시도 정책에서 명시적으로 노출됩니다. |
| ``NetworkError/reachability(_:_:_:)`` | `URLError` 에서 분류된 DNS, 오프라인, 연결 끊김, 셀룰러 데이터 사용 불가. ``ReachabilityReason`` 참고. | 네트워크 reachability 로 처리. 요청이 안전하고 정책 예산이 허용하면 재시도. |
| ``NetworkError/underlying(_:_:)`` | 내장 mapper 가 분류하지 않은 transport 오류, 또는 저장된 응답과 맞출 수 없는 `304 Not Modified` (domain `InnoNetwork.ResponseCache`, code `304`). | `SendableUnderlyingError.domain` 과 `.code` 로 더 깊은 triage. |
| ``NetworkError/trustEvaluationFailed(_:)`` | TLS pinning 또는 사용자 정의 신뢰 평가기가 인증서 체인 거부. | 사용자에게 노출. 자동 재시도 금지. |
| ``NetworkError/cancelled`` | `Task` 취소 또는 `cancelAll()`. | 조용히 존중. 호출부의 의도된 중단. |
| ``NetworkError/timeout(reason:underlying:)`` | 요청/리소스/연결 타임아웃, 또는 operation 의 ``NetworkOperationDeadline`` 만료 (``TimeoutReason/operationDeadline(_:)``). | 예산이 허용하면 재시도. |
| ``NetworkError/policyRejected(_:)`` | 로컬에 설정한 정책이 교환을 보내거나, 계속하거나, 받아들이기를 거부. ``NetworkPolicyRejection`` 참고. | 같은 요청을 즉시 재시도하지 않음. 결과가 같습니다. |
| ``NetworkError/authentication(_:)`` | 세션을 더 이상 갱신할 수 없거나, 이름 있는 request credential 을 선택·획득·적용하지 못함. ``NetworkAuthenticationFailure`` 참고. | 다시 로그인하도록 안내하거나 credential provider 를 수정. 자동 재시도되지 않음. |

### 연결 실패 이유

``NetworkError/reachability(_:_:_:)`` 와 오프라인을 뜻하는
``NetworkError/configuration(reason:)`` 이 라이브러리의 연결 실패입니다. 기기에
host 로 가는 사용 가능한 경로가 없고, 네트워크 경로가 바뀌면 해결될 수 있는
실패입니다. ``RetryPolicy/waitsForNetworkChanges`` 를 켜면 재시도는 이 실패 뒤에만
경로 변경을 기다립니다. ``NetworkErrorSummary/recovery`` 는 오프라인 실패에는
항상, reachability 실패에는 요청을 다시 보내도 될 때
``NetworkRecoveryDisposition/waitForConnectivity`` 를 권고합니다. 다운로드
재시도도 같은 `URLError` 표를 사용합니다.

| 이유 | 원본 `URLError` |
|------|-----------------|
| ``ReachabilityReason/notConnectedToInternet`` | `URLError.notConnectedToInternet` |
| ``ReachabilityReason/dnsLookupFailed`` | `URLError.dnsLookupFailed` |
| ``ReachabilityReason/cannotFindHost`` | `URLError.cannotFindHost` |
| ``ReachabilityReason/networkConnectionLost`` | `URLError.networkConnectionLost` |
| ``ReachabilityReason/cellularDataUnavailable`` | `URLError.dataNotAllowed`, `URLError.internationalRoamingOff`, `URLError.callIsActive` |

underlying ``SendableUnderlyingError`` 는 정확한 `URLError` code 를 그대로
유지하므로 `URLError.Code(rawValue: underlying.code)` 로 세 셀룰러 code 를 여전히
구분할 수 있습니다. `URLError.cannotConnectToHost` 는 reachability 실패가 아니라
``TimeoutReason/connectionTimeout`` 을 담은
``NetworkError/timeout(reason:underlying:)`` 입니다. `default` 없이
``ReachabilityReason`` 을 switch 한다면 7.0 에서 추가된 `.cellularDataUnavailable`
도 처리해야 합니다.

### 정책 거부

``NetworkError/policyRejected(_:)`` 는 서버 상태에 대해 아무것도 말하지 않습니다.
내장 재시도 정책은 이 실패를 재시도하지 않고, circuit breaker 도 host 실패로
세지 않습니다.

| 거부 | 원인 | 안정 코드 |
|------|------|-----------|
| ``NetworkPolicyRejection/responseBodyLimitExceeded(limitBytes:observedBytes:)`` | 응답 본문이 ``ResponseBodyBufferingPolicy`` 한도를 초과. `observedBytes` 는 수집된 크기이며, 본문을 읽기 전에 거부된 경우 선언된 `Content-Length` 입니다. | `4003` |
| ``NetworkPolicyRejection/circuitOpen(_:)`` | 요청 host 의 circuit breaker 가 열려 있음. payload 는 `host` 와 `retryAfter` 를 가진 ``CircuitBreakerOpenError`` 입니다. | `4011` |
| ``NetworkPolicyRejection/rateLimitQueueFull`` | 크기가 제한된 rate-limit 큐가 가득 참. | `4008` |
| ``NetworkPolicyRejection/rateLimitScopeLimitReached`` | 크기가 제한된 rate-limit scope registry 가 가득 참. | `4009` |
| ``NetworkPolicyRejection/admissionQueueFull`` | 크기가 제한된 request-admission 큐가 가득 참. | `4006` |
| ``NetworkPolicyRejection/admissionWaitExpired`` | 요청이 admission 큐에서 deadline 을 넘겨 대기. | `4007` |
| ``NetworkPolicyRejection/nonHTTPResponse`` | transport 가 HTTP 가 아닌 응답을 전달. | `3002` |

### 인증 실패

``NetworkError/authentication(_:)`` 는 transport 전 또는 후에 요청을 인증할 수
없었다는 뜻입니다. 갱신이 성공한 뒤 서버가 반환한 `401` 은
``NetworkError/statusCode(_:)`` 로 남습니다.

| 실패 | 원인 | 안정 코드 |
|------|------|-----------|
| ``NetworkAuthenticationFailure/refreshFailed(_:)`` | 갱신 시도로 세션을 더 이상 갱신할 수 없다는 사실이 드러남. 갱신 요청이 일시적이지 않은 status (예: `400 invalid_grant`, `401`, `403`, `404`) 나 `.userAuthenticationRequired` 같은 credential 거부 `URLError` 로 거부되었거나, token 응답을 디코딩할 수 없었거나, 갱신 클로저가 앱 자체 타입의 오류를 던진 경우입니다. payload 는 갱신 작업이 만든 오류입니다. | `6001` |
| ``NetworkAuthenticationFailure/credential(_:)`` | 이름 있는 request credential 실패. payload 는 secret 이 없는 ``RequestSecurityFailure`` 입니다. | `6002` |

이 규칙은 모든 갱신에 똑같이 적용됩니다. 갱신 대상 status 뒤의 재실행과, 아직
token 이 없는 `.required` 요청의 사전 갱신 모두 같습니다. 세션 상태에 대해
아무것도 알려 주지 않는 이유로 갱신이 실패하면, 세션이 여전히 유효할 수 있으므로
그 실패는 원래의 case 를 유지합니다. 취소, 연결 실패, 타임아웃, 갱신 endpoint 의
`408`·`429`·`5xx` (이때 ``NetworkError/statusCode(_:)`` 는 갱신 endpoint 의
응답을 담되, refresh token 이 든 갱신 요청은 담지 않습니다), 분류되지 않은 transport 오류, 기기 오프라인을 포함한
configuration 실패, token host 의 circuit 이 열린 경우 같은 로컬 정책 거부, 신뢰
평가 실패가 여기에 해당합니다. 일시적 실패로 볼 수 있는 오류는 transport 에서 온
오류, 즉 ``NetworkError`` 나 `URLError` 뿐이며, 거부된 credential 을 알리는
`URLError` (`.userAuthenticationRequired`, `.userCancelledAuthentication`,
`.clientCertificateRejected`, `.clientCertificateRequired`) 는 일시적 실패가
아닙니다. 갱신 클로저가 던진 그 밖의 오류는 `.refreshFailed` 가 됩니다. 원래의
case 를 유지한 실패는 일반적인 재시도·회복 규칙을 따릅니다. <doc:AuthRefresh> 를
참고하세요.

이름 있는 credential 도 같은 규칙을 따릅니다. credential provider 자신의
transport 가 일시적으로 실패하면 — credential 거부가 아닌 `URLError`, 또는 연결
실패나 타임아웃 같은 ``NetworkError`` — 요청은
``RequestSecurityFailure/credentialUnavailable`` 이나
``RequestSecurityFailure/refreshFailed`` 대신 그 실패의 secret 없는 분류를
보고합니다. 예를 들어 underlying 오류가 domain 과 code 를 유지하고 메시지가
"Credential-protected transport failed." 인 ``NetworkError/reachability(_:_:_:)``
입니다. provider 가 받은 일시적인 HTTP status 는 provider 의 응답을 드러낼 수
있으므로 여전히 `.credentialUnavailable` 이 됩니다. 갱신이 provider 자신의
transport 에 대한 로컬 정책 거부, 신뢰 평가 실패, configuration 실패로 멈춘
경우에도 세션 갱신과 마찬가지로 그 분류를 유지하며, 다시 로그인하라고 권하지
않습니다. 이름 있는 credential 을
준비하는 중에 난 실패는 circuit breaker 가 요청 host 의 실패로 세지 않습니다.
<doc:RequestCredentials> 를 참고하세요.

## 재시도, circuit breaker, 회복 권고가 공유하는 단일 분류

실패가 일시적인지 판단하는 규칙은 하나입니다. ``NetworkError/isRetriableHint``,
``ExponentialBackoffRetryPolicy``, circuit breaker,
``NetworkErrorSummary/recovery`` 가 모두 같은 규칙을 읽습니다.

| Case | ``NetworkError/category`` | 일시적 | circuit breaker 집계 |
|------|---------------------------|--------|----------------------|
| `.statusCode` 의 `5xx` | `.statusCode` | 예 | 예 |
| `.statusCode` 의 `408`, `429` | `.statusCode` | 예 | 아니요. `4xx` 응답은 rolling window 에서 제외됩니다. |
| `.statusCode` 의 그 밖의 status | `.statusCode` | 아니요 | 아니요 |
| `.underlying` (취소 제외) | `.transport` | 예. 단, 결정적 `URLError` 는 아니요 | 예. 단, 결정적 `URLError` 와 맞출 수 없는 `304` 는 집계하지 않습니다. 그 `304` 는 이미 성공으로 기록된 뒤에 발생합니다. TLS 실패는 결정적 인증서 실패를 포함해, 정책이 transport-security 실패를 집계할 때만 집계합니다. |
| `.reachability` | `.reachability` | 예 | 예. 단, `.notConnectedToInternet` 과 `.cellularDataUnavailable` 은 아니요 |
| `.timeout` | `.timeout` | 예 | 예 |
| `.trustEvaluationFailed` | `.trust` | 아니요 | ``CircuitBreakerPolicy/countsTransportSecurityFailures`` 가 `true` 일 때만 |
| `.configuration` | `.configuration` | 아니요 | 아니요 |
| `.decoding` | `.decoding` | 아니요 | 아니요 |
| `.cancelled` | `.cancellation` | 아니요 | 아니요 |
| `.policyRejected` | `.policy` | 아니요 | 아니요 |
| `.authentication` | `.authentication` | 아니요 | 아니요 |

circuit breaker 열은 요청 자신의 교환에서 난 실패를 설명합니다. 이름 있는
request credential 을 획득·갱신·서명하는 중에 난 실패는 case 와 관계없이 집계하지
않으며, 실패한 세션 갱신도 집계하지 않습니다. 사용 가능한 네트워크 경로가 아예
없는 기기 — ``ReachabilityReason/notConnectedToInternet`` 이나
``ReachabilityReason/cellularDataUnavailable`` — 도 특정 host 에 대한 증거가
아니므로 집계하지 않습니다. 집계하면 오프라인 동안 쓴 모든 host 의 circuit 이
열리고, 다시 연결된 직후의 요청이 거절됩니다.

결정적 `URLError` 는 같은 요청을 다시 보내도 결과가 바뀌지 않는 오류입니다. App
Transport Security 차단(`.appTransportSecurityRequiresSecureConnection`), 잘못된
또는 지원하지 않는 URL(`.badURL`, `.unsupportedURL`), 반복되거나 갈 곳 없는
redirect(`.httpTooManyRedirects`, `.redirectToNonExistentLocation`), 시스템이
신뢰하지 않는 서버 인증서나 거부된 클라이언트 인증서
(`.serverCertificateUntrusted`, `.serverCertificateHasBadDate`,
`.serverCertificateNotYetValid`, `.serverCertificateHasUnknownRoot`,
`.clientCertificateRejected`, `.clientCertificateRequired`), 서버가 거부한
credential(`.userAuthenticationRequired`, `.userCancelledAuthentication`),
로컬 파일이나 크기 제한 실패(`.fileDoesNotExist`, `.fileIsDirectory`,
`.noPermissionsToReadFile`, `.dataLengthExceedsMaximum`)가 해당합니다. 재시도하지
않으며 circuit breaker 도 집계하지 않습니다. 단, 인증서 실패는 다른 TLS 실패와
마찬가지로 ``CircuitBreakerPolicy/countsTransportSecurityFailures`` 가 `true` 일
때 집계합니다.

``NetworkError/isRetriableHint`` 는 오류 종류가 보통 일시적인지만 답합니다.
요청 method, idempotency key, 시도 예산까지 확인하는 ``RetryPolicy`` 를 대체하지
않습니다.

## 레시피: 먼저 분류로 분기

```swift
func presentation(for error: NetworkError) -> ErrorPresentation {
    switch error.category {
    case .cancellation:
        return .silent
    case .configuration:
        return error.isUserVisible ? .offline : .developerIssue
    case .reachability, .timeout, .transport:
        return error.isRetriableHint ? .retryableNetwork : .networkFailure
    case .statusCode:
        return error.isRetriableHint ? .retryableServer : .serverRejected
    case .decoding:
        return .unexpectedResponse
    case .trust:
        return .securityFailure
    case .policy:
        return .locallyRejected  // 재시도해도 결과가 같습니다
    case .authentication:
        // 사용자가 필요한 것은 세션이나 credential 이 만료된 경우뿐입니다.
        // 코드가 credential 계약을 잘못 쓴 경우는 사용자에게 보이지 않습니다.
        if error.summary.recovery == .reauthenticate { return .signInRequired }
        return error.isUserVisible ? .credentialUnavailable : .developerIssue
    }
}
```

## 레시피: 필요할 때 구조화된 payload 로 분기

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

    case .reachability(.cellularDataUnavailable, _, _):
        return .cellularDataOff  // Wi-Fi 에 연결하면 해결될 수 있음

    case .statusCode(let response) where (500...599).contains(response.statusCode):
        return .recoverableServer

    case .statusCode(let response) where response.statusCode == 401:
        return .reauthenticate

    case .authentication(.refreshFailed):
        return .reauthenticate  // 세션을 더 이상 갱신할 수 없음

    case .policyRejected(.responseBodyLimitExceeded(let limitBytes, let observedBytes)):
        return .responseTooLarge(limit: limitBytes, observed: observedBytes)

    case .policyRejected(.circuitOpen(let open)):
        return .temporarilyUnavailable(retryAfter: open.retryAfter)

    case .configuration(reason: .offline):
        return .offline

    case .trustEvaluationFailed:
        return .securityFailure  // 자동 재시도 금지

    default:
        return .failure(error)
    }
}
```

`NetworkError` 는 `@frozen` 이 아니므로 새 case 가 추가될 수 있습니다. 일부
case 만 다루는 switch 는 위처럼 `default` 로 닫고, 모든 case 를 나열하는 switch
에는 끝에 `@unknown default` 를 두세요. `default` 없이 ``NetworkError`` 나 ``NetworkErrorCategory`` 를 switch 한다면
`.policyRejected` 와 `.authentication`, 그리고 `.policy` 와 `.authentication` 을
포함한 모든 case 를 나열해야 하고, ``ReachabilityReason`` 을 switch 한다면
`.cellularDataUnavailable` 도 나열해야 합니다. 핵심은 **helper bucket, 또는 case +
구조화된 페이로드**로 분기하고, 문자열 비교에 의존하지 않는 것입니다. 호출
지점에서 두 화면 떨어진 코드도 라이브러리 변경에 안정적으로 견딥니다.

## 레시피: payload 없는 summary 보관

``NetworkErrorSummary`` 는 category, 안정적인 숫자 코드, HTTP status, 권장 회복
동작만 유지합니다. 응답 본문, 헤더, URL, underlying 오류 문자열을 담지 않으므로
view state 에 저장하거나, 테스트에서 비교하거나, 분석으로 보내기에 안전합니다.

```swift
do {
    let user = try await client.request(GetUser())
    render(user)
} catch {
    let summary = error.summary
    analytics.record(category: summary.category, code: summary.code, status: summary.statusCode)
}
```

``NetworkError/summary`` 는 요청 컨텍스트가 없어 재실행이 안전한지 알 수
없습니다. transport 이후의 실패에는 `.retry` 나 `.waitForConnectivity` 대신
``NetworkRecoveryDisposition/doNotRetry`` 를 보고하고,
``NetworkRecoveryDisposition/reauthenticate`` 는 명시적인
``NetworkError/authentication(_:)`` 실패에만 보고합니다. 컨텍스트는
``NetworkError/summary(method:authentication:replaySafety:)`` 로 직접 제공하거나
operation 이 제공하게 하세요.

```swift
let operation = client.start(GetUser())
do {
    let user = try await operation.value()
    render(user)
} catch {
    // operation 은 method, authentication, replay safety 를 알고 있습니다.
    let summary = await operation.failureSummary() ?? error.summary
    switch summary.recovery {
    case .retry: offerRetry()  // 시도 예산은 여전히 호출부 책임입니다
    case .waitForConnectivity: showOfflineState()
    case .reauthenticate: presentSignIn()
    case .doNotRetry, .none: showFailure(summary.description)
    }
}
```

같은 summary 가 operation 의 이벤트 스트림에
``NetworkOperationEvent/failed(id:summary:)`` 로 전달됩니다.

## 실패 페이로드 캡처

`NetworkError.decoding(stage:underlying:response:)` 는 실패한 디코딩의 `Response`
를 함께 들고 옵니다. 기본 동작은 오류가 노출되기 전에 `response.data` 를 빈
Data 로 redact 하는 것입니다.

원본 응답 본문은 advanced configuration에
`CachePack(captureFailurePayload: true)` 를 전달해 명시적으로 opt-in 한
경우에만 보존됩니다. 프로덕션에서는 PII 가 크래시 리포트, 분석, 로그에
유출되지 않도록 이 플래그를 꺼 두세요.

## NSError 브리지

`NetworkError` 는 안정 도메인 `com.innosquad.innonetwork` 로 NSError 브리지가
됩니다. 숫자 코드는 안정적으로 유지되므로, 관측 가능성 파이프라인이
지역화 문자열을 파싱하지 않고도 실패를 그룹화할 수 있습니다. 기저 Foundation
오류는 `.underlying` / timeout case 안에 ``SendableUnderlyingError`` 로
보존되지만, ``NetworkError/errorCode`` 는 Foundation `URLError.Code` 가 아니라
항상 InnoNetwork 소유 ``NetworkErrorCode`` 값을 반환합니다. status code 실패는
구조화된 ``Response`` 메타데이터를 유지합니다.

정책 거부와 인증 실패는 일반 코드 `4001` 이 아니라 위 표의 고유 코드를
보고합니다. 정책 거부는 메시지 문자열을 들고 있지 않으며, `errorDescription` 은
payload 로부터 만들어지고 지역화됩니다.

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
- ``NetworkErrorCategory``
- ``NetworkErrorSummary``
- ``NetworkPolicyRejection``
- ``NetworkAuthenticationFailure``
- ``SendableUnderlyingError``
- <doc:ErrorClassification>
