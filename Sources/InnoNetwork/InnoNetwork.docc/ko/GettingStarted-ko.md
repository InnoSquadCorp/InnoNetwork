# 시작하기

안전한 기본값으로 클라이언트를 만들고, 명시적인 구조체와
``APIDefinition(method:path:auth:)`` macro 로 요청을 모델링한 다음
``DefaultNetworkClient`` 를 통해 호출하는 방법을 설명합니다.

> 한국어 번역본 (영문 원본 → <doc:GettingStarted>) 입니다. 두 문서의 내용이
> 일치하지 않을 때는 영문 원본의 정의를 우선합니다.

> 이 문서는 `main`의 미출시 5.0 프리뷰를 기준으로 합니다. 태그된 최신 안정 버전은
> `4.0.0`입니다. 프리뷰를 평가할 때는 검토한 revision으로 고정하고, 프로덕션에서
> 움직이는 `main` branch를 직접 의존하지 마세요.

## 클라이언트 만들기

```swift
import Foundation
import InnoNetwork

let client = DefaultNetworkClient(
    configuration: .safeDefaults(
        baseURL: URL(string: "https://api.example.com/v1")!
    )
)
```

`safeDefaults(baseURL:)` 는 prototype, test, 또는 회복탄력성 정책을 다른 계층에서
소유하는 통합의 안전한 출발점입니다. 프로덕션 앱은 보수적인 retry, circuit breaker,
idempotency key, body-size guardrail 을 추가하는
`recommendedForProduction(baseURL:)` 를 우선 검토하세요.

## 요청 정의

```swift
import InnoNetwork

struct User: Decodable, Sendable {
    let id: Int
    let name: String
}

@APIDefinition(method: .get, path: "/users/{id}", auth: .anonymous)
struct GetUser {
    typealias APIResponse = User

    let id: Int
}
```

구조체가 endpoint 계약의 단일 기준입니다. 기본으로 활성화된 macro 는 conformance,
method, percent-encoded path, `sessionAuthentication`, 빈 payload witness 만
생성합니다. `APIResponse` 와 `auth: .anonymous` / `.optional` / `.required`
선택은 자동 추론하지 않고 반드시 명시하게 합니다.

GET/HEAD 의 저장 `query` 또는 POST/PUT/PATCH/DELETE 의 저장 `body` 프로퍼티는
`Parameter` / `parameters` 로 생성됩니다. OPTIONS, CONNECT, TRACE, custom,
dynamic method 는 `Parameter` 와 `parameters` 를 모두 직접 선언해야 합니다.
header, interceptor, transport, decoder 도 구조체에 그대로 명시합니다. 전체 규칙은
<doc:UsingMacros> 를 참고하세요.

## 요청 실행

```swift
let user = try await client.request(GetUser(id: 1))
print(user.name)
```

`request(_:)` 는 `async throws(NetworkError)` 시그니처로 선언되어 있으므로
오류는 항상 ``NetworkError`` 로만 전파됩니다. typed throws 덕분에 별도의
`as NetworkError` 캐스팅 없이 `do/catch` 블록에서 곧바로 case 별 분기로
처리할 수 있습니다.

## 런타임 조합 호출은 `EndpointBuilder` 사용

메서드, 경로, 응답 형태가 런타임에 조합되거나 이름 있는 계약이 필요 없는 일회성
요청이라면 ``EndpointBuilder`` 를 사용합니다.

```swift
let users = try await client.request(
    EndpointBuilder<EmptyResponse>
        .get("/users")
        .authentication(.anonymous)
        .query(["limit": 20])
        .decoding([User].self)
)
```

애플리케이션의 이름 있는 API catalog 는 macro-assisted endpoint 구조체로 유지하고,
multipart 및 streaming 은 각각 전용 definition protocol 을 사용하세요.

엔드포인트 경로는 설정된 base URL 의 경로 뒤에 그대로 이어붙여집니다. 슬래시(`/`)
로 시작하더라도 base URL 의 경로는 보존됩니다. 쿼리는 macro endpoint 의 `query`,
manual endpoint 의 `parameters`, 또는 ``EndpointBuilder/query(_:)`` 에서 표현합니다.
macro path 의 `?` / `#` 는 컴파일 시점에, hand-written/runtime path 는
``NetworkError/configuration(reason:)`` 으로 거부됩니다.

macro 는 root `InnoNetwork` product 의 기본 `Macros` trait 로 제공됩니다. 사용하지 않는
consumer 는 dependency 에 `traits: []` 를 지정해 macro API 와 compiler plug-in compile 을
제외할 수 있습니다. 다만 SwiftPM 은 manifest-level dependency 를 resolve/fetch 할 수 있고,
trait 는 graph 전체에서 package 단위로 합쳐져 다른 dependency 가 기본 trait 를 켜면 다시
활성화될 수 있습니다.

## 요청 실행 계약

일반 요청은 ``NetworkClient/request(_:)``, multipart 업로드는
``NetworkClient/upload(_:)`` 만 사용하세요. 저수준 generated-client 훅은
`@_spi(GeneratedClientSupport)` 이며 5.0 공개 계약 초안 밖에 있습니다. 프리뷰 기간에는
언제든지, 5.0 태그 이후에도 minor release 에서 변경될 수 있으므로 exact source pin 과
migration budget 을 소유한 wrapper 만 사용하세요.
root macro 는 이 SPI 를 노출하거나 bridge 하지 않습니다.

## 고급 설정으로 전환할 때

다음 중 하나가 필요할 때만 ``NetworkConfiguration/safeDefaults(baseURL:)`` 에서
``NetworkConfiguration/advanced(baseURL:resilience:auth:observability:cache:transport:)`` 로 옮기는 것을 권장합니다.

- 재시도 정책의 의미 변경
- TLS 신뢰 평가 동작 변경
- 이벤트 전달 정책 변경
- 메트릭/관측 가능성(observability) 리포터 추가

위 항목 이외의 튜닝은 가능한 한 안전한 기본값 위에서 endpoint 단위로 조정하는
편이 향후 마이너 릴리스의 변경 면적을 줄입니다.
