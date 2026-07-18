# 인증 토큰 갱신

인증 응답 이후 bearer 토큰을 갱신하고 완전히 적용된 요청을 한 번만 재실행해야
할 때 ``RefreshTokenPolicy`` 를 사용합니다.

> 한국어 번역본 (영문 원본 → <doc:AuthRefresh>) 입니다. 두 문서의 내용이
> 일치하지 않을 때는 영문 원본의 정의를 우선합니다.

토큰 갱신은 InnoNetwork 의 내부 실행 파이프라인에 포함된 동작이며, 공개되는
재시도 정책이 아닙니다. 공개 표면은 좁게 유지됩니다 — 호출부는 현재 토큰을
읽고, 갱신하고, 선택적으로 ``URLRequest`` 에 적용하는 클로저만 제공합니다.

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
- 갱신이 실패하면 모든 대기 중인 요청에 동일한 오류가 전파됩니다. **실패한
  갱신은 캐시되지 않습니다** — 다음 `401` 에서는 새로운 갱신을 처음부터
  다시 시도합니다.

`refreshStatusCodes:` 나 `applyToken:` 은 표준 bearer 흐름과 다른 API 에
적응해야 할 때만 명시적으로 지정하세요.

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
- 첫 번째 호출자가 취소되면 코디네이터는 후속 호출자가 새 갱신을 시작할 수
  있도록 상태를 다시 idle 로 되돌립니다. 후속 호출자가 새 클로저를 실행하므로
  취소가 곧 영구적인 갱신 실패로 굳지 않습니다.
- 모든 대기자는 새 토큰 또는 동일한 갱신 오류를 단일 일관 상태에서 관찰합니다.

이 contract 는 `RefreshCoalescerRaceTests` 에서 회귀가 잠겨 있습니다.
