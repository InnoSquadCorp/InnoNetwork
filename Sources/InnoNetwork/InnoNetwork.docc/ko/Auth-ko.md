# 인증 토큰 갱신

인증 응답 이후 bearer 토큰을 갱신하고 완전히 적용된 요청을 한 번만 재실행해야
할 때 ``RefreshTokenPolicy`` 를 사용합니다.

> 한국어 번역본 (영문 원본 → <doc:AuthRefresh>) 입니다. 두 문서의 내용이
> 일치하지 않을 때는 영문 원본의 정의를 우선합니다.

토큰 갱신은 InnoNetwork 의 내부 실행 파이프라인에 포함된 동작이며, 공개되는
재시도 정책이 아닙니다. 공개 표면은 좁게 유지됩니다 — 호출부는 현재 토큰을
읽고, 갱신하고, 선택적으로 `URLRequest` 에 적용하는 클로저만 제공합니다.

```swift
let refreshPolicy = RefreshTokenPolicy(
    currentToken: {
        try await tokenStore.currentAccessToken()
    },
    refreshToken: {
        try await authService.refreshAccessToken()
    }
)

let client = DefaultNetworkClient(
    configuration: .advanced(
        baseURL: URL(string: "https://api.example.com")!,
        auth: AuthPack(refreshToken: refreshPolicy)
    )
)
```

기본 동작은 다음과 같습니다.

- 토큰이 있으면 transport 단계 전에 현재 토큰을 적용합니다.
- `401` 응답에서 갱신을 시도합니다.
- 동시에 발생한 갱신은 단일 in-flight 작업으로 합쳐집니다 (single-flight).
- 완전히 적용된 요청을 최대 한 번 재실행합니다. 세션/엔드포인트 인터셉터가
  추가한 헤더는 보존되며, 이전 `Authorization` 헤더는 제거된 뒤 새 토큰으로
  다시 적용됩니다 — `setValue` 기반 적용기뿐만 아니라 `addValue` 로 헤더를
  쌓는 적용기에서도 이 사전 제거 단계 덕분에 토큰 재적용(idempotent
  reapplication)이 중복 헤더를 만들지 않고 마무리됩니다.
- 갱신이 실패하면 모든 대기 중인 요청에 동일한 오류가 전파되고, 짧은 실패
  cooldown (`failureCooldown:`, 기본값은 1초에서 시작해 최대 30초까지의 지수
  증가) 이 시작됩니다. cooldown 중에 도착한 `401` 은 실패한 것으로 알려진
  갱신을 다시 호출하지 않고 같은 갱신 오류로 실패합니다. cooldown 이 끝나면
  다음 `401` 에서 새로운 갱신을 시도합니다. 모든 실패를 즉시 다시 시도하려면
  `failureCooldown: .disabled` 를 전달하세요.
- `stream(_:)` handshake 가 갱신 대상 status 로 거부되면, 본문 byte 가 전달되기
  전에 같은 방식으로 한 번만 재실행합니다.

`refreshStatusCodes:` 나 `applyToken:` 은 표준 bearer 흐름과 다른 API 에
적응해야 할 때만 명시적으로 지정하세요.

## 갱신 실패 처리

세션 갱신이 세션을 더 이상 갱신할 수 없다는 사실을 보여 주며 실패하면, 요청은
``NetworkError/authentication(_:)`` 과
``NetworkAuthenticationFailure/refreshFailed(_:)`` 를 던집니다. 이 규칙은 모든
갱신에 똑같이 적용됩니다. 갱신 대상 status (기본값 `401`) 뒤의 재실행과, 아직
token 이 없는 `.required` 요청의 사전 갱신 모두 같습니다. 다음 경우가 여기에
해당합니다.

- 서버가 갱신 요청을 일시적이지 않은 status 로 거부한 경우. 예를 들어
  `400 invalid_grant`, `401`, `403`, `404` 입니다.
- 거부된 credential 을 알리는 `URLError` 인 경우.
  `.userAuthenticationRequired`, `.userCancelledAuthentication`,
  `.clientCertificateRejected`, `.clientCertificateRequired` 입니다.
- token 응답을 디코딩할 수 없는 경우
- `refreshToken` 클로저가 앱 자체 타입의 오류를 던진 경우

payload 는 갱신 작업이 만든 오류의 ``SendableUnderlyingError`` snapshot 입니다.
요청을 다시 보내도 세션을 복구할 수 없으므로 내장 재시도 정책은 이 실패를
재시도하지 않고, circuit breaker 도 집계하지 않으며,
``NetworkErrorSummary/recovery`` 는
``NetworkRecoveryDisposition/reauthenticate`` 를 권고합니다.

```swift
do {
    let profile = try await client.request(GetProfile())
    render(profile)
} catch NetworkError.authentication(.refreshFailed) {
    await session.signOut()
    presentSignIn()
} catch {
    present(error)
}
```

세션 상태에 대해 아무것도 알려 주지 않는 이유로 갱신이 실패하면, 세션은 여전히
유효할 수 있으므로 갱신 오류가 원래의 case 를 그대로 유지합니다. 이때 요청은
일반적인 재시도·회복 규칙을 따릅니다.

- 취소는 ``NetworkError/cancelled`` 로 남습니다.
- 연결 실패는 ``NetworkError/reachability(_:_:_:)``, 타임아웃은
  ``NetworkError/timeout(reason:underlying:)`` 으로 남습니다.
- 갱신 endpoint 가 반환한 `408`, `429`, `5xx` 는
  ``NetworkError/statusCode(_:)`` 로 남습니다. 이때 ``Response`` 는 원래 요청의
  응답이 아니라 갱신 endpoint 의 응답이며, 요청은 담지 않습니다. 갱신 요청의
  본문과 헤더에는 refresh token 이 들어 있기 때문입니다.
- 그 밖의 `URLError` 는 분류되지 않은 transport 오류이며
  ``NetworkError/underlying(_:_:)`` 로 남습니다.
- 기기 오프라인을 포함한 configuration 실패는
  ``NetworkError/configuration(reason:)`` 으로 남습니다. token host 의 circuit
  이 열린 경우 같은 로컬 정책 거부는 ``NetworkError/policyRejected(_:)``, 신뢰
  평가 실패는 ``NetworkError/trustEvaluationFailed(_:)`` 로 남습니다.

일시적 실패로 볼 수 있는 오류는 transport 에서 온 오류, 즉 ``NetworkError`` 나
`URLError` 뿐이며, 거부된 credential 을 알리는 `URLError` 는 일시적 실패가
아닙니다. `refreshToken` 클로저가 던진 그 밖의 타입의 오류는 세션에 대한 클로저의
판정으로 취급하므로, token client 가 받은 `URLError` 나 ``NetworkError`` 는 앱
자체 오류 타입으로 감싸지 말고 그대로 다시 던지세요. InnoNetwork client 로 보낸
갱신 요청은 이미 status 를 ``NetworkError/statusCode(_:)`` 로 보고합니다. HTTP
status 를 직접 확인하는 token client 는 저장소의 Auth 예제를 따르면 됩니다. 갱신
credential 을 거부하는 `400`, `401`, `403` 에는
`URLError(.userAuthenticationRequired)` 를, 그 밖의 실패 status 에는 요청을 재시도
가능하게 남기는 `URLError(.badServerResponse)` 를 던집니다.

실패 cooldown 중에 도착한 `401` 은 저장된 갱신 오류로 실패하며, 같은 규칙으로
분류됩니다. 갱신이 성공한 뒤 서버가 반환한 `401` 은
``NetworkError/statusCode(_:)`` 로 남습니다.

## URLSession cache policy

`URLSession` 의 cache 는 credential 이 아니라 URL 로 항목을 구분합니다. 그래서
credential header — `Authorization`, `Proxy-Authorization`, `Cookie`,
`X-API-Key`, `X-Auth-Token`, 또는 `CachePack(sensitiveHeaderNames:)` 에 나열한
header — 를 가진 채 transport 에 도달한 요청의 응답은 cache policy 와 관계없이 이
cache 에 저장되지 않습니다. cache policy 가 기본값인 `.useProtocolCachePolicy` 이면
cache 를 읽지도 않으며, 요청은 `.reloadIgnoringLocalCacheData` 로 전송됩니다.
명시적인 cache 우선 policy 인 `.returnCacheDataElseLoad` 와
`.returnCacheDataDontLoad` 만 두 규칙에서 제외됩니다. 이 검사는 request
interceptor 와 token 적용이 끝난 뒤에 실행되므로, 앱의 request interceptor 가 붙인
credential 과 ``RefreshTokenPolicy`` 가 적용한 token 모두에 적용됩니다.
configuration 을 ``NetworkConfiguration/safeDefaults(baseURL:)`` 로 만들었든
`advanced` 로 만들었든 같습니다. 라이브러리 자체 response cache (``CachePack``)
에는 영향이 없습니다.

`AuthPack(refreshToken:)` 을 설정하면
``NetworkConfiguration/advanced(baseURL:resilience:auth:observability:cache:transport:)``
의 transport 기본값 하나도 달라집니다. ``TransportPack`` 이 `cachePolicy` 를
지정하지 않았다면 그 client 의 모든 요청이 `.reloadIgnoringLocalCacheData` 를
사용합니다. 라이브러리가 credential 로 인식하지 못하는 header 에 token 을 담더라도,
한 세션의 token 으로 받은 응답이 세션이 바뀐 뒤 `URLSession` 의 cache 에서
제공되지 않게 하기 위해서입니다. ``CachePack`` 이 `.disabled` 가 아닌
`responseCachePolicy` 를 설정한 경우에도 같은 기본값이 적용됩니다.

`AuthPack` 을 쓰지 않고 사용자 정의 header 로 credential 을 보내는 client 는 그
header 를 `CachePack(sensitiveHeaderNames:)` 에 추가해 응답이 `URLSession` 의
cache 에 남지 않게 하거나, `TransportPack(cachePolicy: .reloadIgnoringLocalCacheData)`
를 지정하세요.

## 인증 필요 엔드포인트 표시

`.required` 를 명시하면 인증이 필요한 endpoint 가 token provider 없는 client
설정에서 조용히 실행되는 사고를 막을 수 있습니다.

```swift
struct Profile: Decodable, Sendable {
    let id: String
}

let endpoint = EndpointBuilder<EmptyResponse>
    .get("/me")
    .authentication(.required)
    .decoding(Profile.self)

let profile = try await client.request(endpoint)
```

사용자 정의 ``APIDefinition`` 도 동일한 preflight 가드에 옵트인할 수 있습니다.

```swift
struct GetProfile: APIDefinition {
    typealias Parameter = EmptyParameter
    typealias APIResponse = Profile
    let method: HTTPMethod = .get
    let path = "/me"
    let sessionAuthentication: SessionAuthentication = .required
}
```

클라이언트가 `AuthPack(refreshToken:)` 없이 생성되었으면 요청은
transport 단계 전에 ``NetworkError/configuration(reason:)`` 과
``NetworkConfigurationFailureReason/invalidRequest(_:)`` 로 거부됩니다.

이름 있는 수동 endpoint 도 `sessionAuthentication` 을 반드시 선언합니다.
bearer token refresh 에 참여하지 않는 요청은 `.anonymous`, token 이 있으면 사용하되
없어도 전송할 수 있는 요청은 `.optional` 을 선택합니다.

## 동시성/취소 모델 메모

- 갱신 코디네이터는 single-flight 입니다. 첫 번째 호출자가 `refreshToken`
  클로저를 실행하고, 그 사이에 들어온 추가 401 요청은 같은 결과를 기다립니다.
- 대기 중인 호출자가 취소되면 그 호출자만 즉시 반환되고, 공유 갱신 작업은 다른
  대기자를 위해 계속 실행됩니다. 갱신 작업 자체가 취소된 경우에는 상태가 idle 로
  돌아가 후속 호출자가 새 갱신을 시작하므로, 취소가 곧 영구적인 갱신 실패로
  굳지 않습니다.
- 모든 대기자는 새 토큰 또는 동일한 갱신 오류를 단일 일관 상태에서 관찰합니다.

이 contract 는 `RefreshCoalescerRaceTests` 에서 회귀가 잠겨 있습니다.
