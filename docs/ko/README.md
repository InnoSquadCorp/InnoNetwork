# InnoNetwork (한국어)

[![DocC](https://img.shields.io/badge/docs-DocC-blue)](https://innosquadcorp.github.io/InnoNetwork/)
[![Swift](https://img.shields.io/badge/Swift-6.2-orange)](https://swift.org)
[![Platforms](https://img.shields.io/badge/platforms-iOS%2016%20%7C%20macOS%2014%20%7C%20tvOS%2016%20%7C%20watchOS%209%20%7C%20visionOS%201-lightgrey)](#플랫폼-매트릭스)
[![License](https://img.shields.io/badge/license-MIT-blue)](../../LICENSE)

> 이 문서는 [`README.md`](../../README.md) 의 한국어 미러입니다. 정확한 최신 사양은 영문 원본을
> 우선합니다.

InnoNetwork 는 Apple 플랫폼을 위한 타입 안전한 Swift 네트워킹 패키지입니다. root runtime package 는
여덟 개의 공개 product 로 구성되어 있습니다.

- `InnoNetwork` — 요청/응답 API
- `InnoNetworkAuthAWS` — body-aware AWS SigV4 reference signer
- `InnoNetworkDownload` — 다운로드 생명주기 관리
- `InnoNetworkWebSocket` — 연결 지향 실시간 흐름
- `InnoNetworkPersistentCache` — 보수적인 디스크 응답 캐시
- `InnoNetworkTrust` — 선택형 공개키 pinning 평가
- `InnoNetworkTestSupport` — consumer test target용 공개 테스트 helper
- `InnoNetworkOpenAPI` — generated-client transport 지원

`@APIDefinition` macro 는 root `InnoNetwork` product 의 기본 `Macros` trait 로 제공됩니다.
별도 codegen package 나 import 없이 명시적인 endpoint struct 의 반복 코드만 생성하고, 잘못된
정의는 컴파일 진단으로 차단합니다.

Swift Concurrency, 명시적인 transport 정책, 운영 가시성을 중심으로 설계되어 프로토타입부터 프로덕션
클라이언트까지 일관되게 사용할 수 있습니다.

> **릴리즈 상태:** 현재 태그로 공개된 최신 안정 버전은 `4.0.0`입니다. `main`은
> source-breaking 5.0 미출시 프리뷰이며 `5.0.0` 태그는 아직 없습니다. 아래 API 예제는
> 별도로 표시하지 않은 한 현재 `main` 프리뷰를 기준으로 합니다.

> 📚 **API Reference (DocC):** https://innosquadcorp.github.io/InnoNetwork/

---

## Quick Start

### 설치

릴리즈 앱은 태그로 공개된 4.x를 사용하세요.

```swift
dependencies: [
    .package(
        url: "https://github.com/InnoSquadCorp/InnoNetwork.git",
        .upToNextMajor(from: "4.0.0")
    )
]
```

현재 5.0 API를 평가할 때만 `main` 프리뷰를 명시적으로 선택하세요.

```swift
dependencies: [
    .package(
        url: "https://github.com/InnoSquadCorp/InnoNetwork.git",
        branch: "main"
    )
]
```

프로덕션에서 움직이는 `main` branch를 그대로 의존하지 마세요. 프리뷰 CI에서는 검토한
revision으로 고정하거나, `5.0.0`이 출시될 때까지 태그된 4.x를 사용하세요.

### 기본 요청

```swift
import Foundation
import InnoNetwork

@APIDefinition(method: .get, path: "/users/{id}", auth: .anonymous)
struct GetUser {
    typealias APIResponse = User

    let id: Int
}

struct User: Decodable, Sendable {
    let id: Int
    let name: String
}

let client = DefaultNetworkClient(
    configuration: .safeDefaults(
        baseURL: URL(string: "https://api.example.com/v1")!
    )
)

let user = try await client.request(GetUser(id: 1))
print(user)
```

macro 를 사용해도 struct 가 endpoint 계약의 단일 기준입니다. `APIResponse`, 저장 프로퍼티,
custom header/interceptor/transport/decoder 는 struct 에 명시적으로 남고, attribute 는
`method`, `path`, `auth` 를 한눈에 보여 줍니다. `auth:` 는 `.anonymous`, `.optional`,
`.required` 중 하나를 반드시 선택해야 하며 자동 추론하지 않습니다.

- GET/HEAD 의 저장 `query` 프로퍼티는 `Parameter` / `parameters` 로 생성됩니다.
- POST/PUT/PATCH/DELETE 의 저장 `body` 프로퍼티도 같은 방식으로 생성됩니다.
- 복잡한 payload 는 `typealias Parameter` 와 `var parameters` 를 모두 직접 선언하면 그 구현이
  우선합니다.
- `#endpoint` expression macro 는 5.0 프리뷰에서 제거되었습니다. 이름 없는 일회성 요청은
  `EndpointBuilder` 를 사용하세요.

macro 가 전혀 필요 없는 consumer 는 package dependency 에 `traits: []` 를 지정할 수 있습니다.
이 경우 macro API 와 compiler plug-in compile 은 제외되지만, SwiftPM 은 manifest 해석 과정에서
package-level `swift-syntax` dependency 를 resolve/fetch 할 수 있습니다. trait 는 resolved graph
전체에서 package 단위로 합쳐지므로 다른 dependency 가 기본 `Macros` trait 를 켜면 다시
활성화됩니다.

### 다운로드

```swift
import Foundation
import InnoNetworkDownload

// 4.0.0부터는 전역 `DownloadManager.shared` 가 제거되었습니다. 기능별로 고유한
// 세션 식별자를 가진 매니저를 직접 생성해 소유하세요.
let manager = try DownloadManager.make(
    configuration: .safeDefaults(sessionIdentifier: "com.example.app.media")
)
let task = await manager.download(
    url: URL(string: "https://example.com/file.zip")!,
    toDirectory: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
)

for await event in await manager.events(for: task) {
    print(event)
}
```

### WebSocket

```swift
import Foundation
import InnoNetworkWebSocket

let manager = WebSocketManager(configuration: .safeDefaults())
let task = await manager.connect(
    url: URL(string: "wss://echo.example.com/socket")!
)

for await event in await manager.events(for: task) {
    print(event)
}
```

---

## Endpoint 정의 — `transport` 단일 진입점

`APIDefinition` 은 인코딩/디코딩 형태를 단일 프로퍼티 `transport: TransportPolicy<APIResponse>`
로 노출합니다. 기본값은 메서드에 따라 자동 선택되어 (GET/HEAD → `.query()`, 그 외 → `.json()`)
대부분의 endpoint 는 별도 override 없이 작동합니다. 다른 형태가 필요하면 `TransportPolicy`
factory 를 사용하세요.

아래 `/me` 예시는 `AuthPack(refreshToken:)` 으로 `RefreshTokenPolicy` 를
설정한 client 를 전제로 합니다. `.required` 요청은 해당 정책이 없으면 transport 전에
실패합니다.

```swift
struct UpdateProfile: APIDefinition {
    typealias Parameter = ProfileBody
    typealias APIResponse = Profile

    let parameters: ProfileBody?
    var method: HTTPMethod { .patch }
    var path: String { "/me" }
    var sessionAuthentication: SessionAuthentication { .required }

    var transport: TransportPolicy<Profile> {
        .json(decoder: snakeCaseDecoder)
    }
}

// form-url-encoded 로그인
let token = try await client.request(
    EndpointBuilder<EmptyResponse>
        .post("/login")
        .body(credentials)
        .authentication(.anonymous)
        .transport(.formURLEncoded())
        .decoding(Token.self)
)

let profile = try await client.request(
    EndpointBuilder<EmptyResponse>
        .get("/me")
        .authentication(.required)
        .decoding(Profile.self)
)
```

---

## 태그 기반 부분 취소

`request(_:tag:)` / `upload(_:tag:)` 로 보낸 요청은 `CancellationTag` 단위로 묶여
`cancelAll(matching:)` 를 통해 일부만 취소할 수 있습니다. 화면, 기능, 사용자 세션이
사라질 때 다른 호출을 건드리지 않고 자기 요청만 정리할 때 사용합니다.

```swift
let feed: CancellationTag = "feed"

async let posts = client.request(GetPosts(), tag: feed)
async let banner = client.request(GetBanner(), tag: feed)

await client.cancelAll(matching: feed)  // feed 태그만 취소
```

---

## 응답 캐시와 Vary 헤더

`ResponseCachePolicy` 는 응답의 `Vary` 헤더를 자동으로 처리합니다 (RFC 9111 §4.1).

- `Vary: *` 응답은 캐시되지 않습니다.
- `Vary: Accept-Language` 같은 명시 헤더는 저장 시점의 요청 헤더 값을 함께 캡처해
  이후 lookup 에서 동일 값일 때만 hit 으로 인정합니다.
- `Vary` 헤더가 없는 응답은 저장 조건을 통과한 경우 기존 키 정책
  (Authorization 등) 으로 분리됩니다.
- GET 응답 중 전체 표현을 재사용할 수 있는 cacheable status (`200`, `203`, `204`,
  `300`, `301`, `308`, `404`, `405`, `410`, `414`, `501`) 는 저장 대상입니다.
- `Cache-Control: no-store` 와 `Cache-Control: private` 는 현재 키를 무효화하고
  저장하지 않습니다. `Cache-Control: no-cache` 는 저장하되 매 lookup 마다
  재검증을 강제합니다.
- `Authorization` 요청의 응답은 origin 이 `Cache-Control: public`,
  `must-revalidate`, `s-maxage` 중 하나로 명시적으로 허용할 때만 저장됩니다.
- `POST`, `PUT`, `PATCH`, `DELETE` 같은 unsafe method 가 `2xx`/`3xx` 응답을
  받으면 RFC 9111 §4.4 에 따라 같은 target URI 의 캐시 변형을 모두
  무효화합니다. `.disabled` 와 `.networkOnly` 정책은 캐시 메타데이터를
  건드리지 않습니다.

---

## 플랫폼 매트릭스

- iOS 16.0+
- macOS 14.0+
- tvOS 16.0+
- watchOS 9.0+
- visionOS 1.0+
- Swift 6.2+

본 패키지는 의도적으로 최신 Apple 플랫폼만을 타겟합니다. 이를 통해 모던 Swift Concurrency,
엄격한 Sendable 검증, 최신 URLSession 및 플랫폼 API 를 호환 shim 없이 사용할 수 있습니다.

---

## Production Checklist

InnoNetwork 기반 클라이언트를 출시하기 전에 점검해야 할 운영 항목입니다.

### TLS / 인증

- **핀 회전.** `import InnoNetworkTrust` 후
  `TrustPolicy.custom(PublicKeyPinningEvaluator(...))` 사용 시 최소 두 개의 핀(현재 + 다음)을
  함께 배포해 인증서 교체 후에도 검증이 끊기지 않도록 합니다. 비상 복구를 위해 feature flag 로
  `.systemDefault` 로 되돌릴 수 있는 경로를 마련하세요.
- **App Transport Security (ATS).** `safeDefaults` 는 ATS 활성을 가정합니다. 프로덕션
  `Info.plist` 에서 `NSAllowsArbitraryLoads` 를 사용하지 마세요. 비-HTTPS 호스트가 불가피하다면
  `NSExceptionDomains` 로 해당 호스트만 한정합니다.
- **커스텀 trust 평가.** `TrustEvaluating` 구현은 응답 디코딩보다 먼저 실행되며, throw 된 에러는
  `NetworkError.trustEvaluationFailed` 로 노출됩니다. 사용자 복구 흐름으로 연결하고, 신뢰 실패에
  자동 재시도를 걸지 마세요.

### 백그라운드 동작

- **Background Download Info.plist.** URLSession 백그라운드 다운로드 자체에는
  `UIBackgroundModes` 가 필요하지 않습니다. 푸시로 다운로드를 시작하는 앱만
  `remote-notification` 을 선택적으로 선언합니다.
- **세션 식별자 유일성.** `DownloadConfiguration.sessionIdentifier` 는 앱 프로세스 내에서
  전역적으로 유일해야 합니다. 중복 시 Foundation 이 task 를 병합하므로, 라이브러리는 DEBUG 에서
  assert, RELEASE 에서 OSLog `.fault` 를 발생시킵니다.
- **백그라운드 완료 핸들러.** 시스템이 전달하는
  `application(_:handleEventsForBackgroundURLSession:completionHandler:)` 핸들러를
  `DownloadManager` 와 연결해서 OS 가 앱 서스펜션을 빠르게 해제하도록 합니다.

### 관측성 / 프라이버시

- **Redaction 기본값.** `NetworkEvent` 는 헤더와 본문을 전달하지 않습니다. 모든 observer가
  이벤트를 받기 전에 URL user-info/fragment를 제거하고 query 값을 가리며 JWT 형태의 path 값을
  masking합니다. 실패 메시지도 payload가 없는 안정된 category만 전달합니다. secure
  `NetworkLogger` 는 모든 헤더 값, cookie, 본문, query 값, 자유 형식 오류 설명까지 추가로
  redaction합니다. `NetworkLoggingOptions.verbose` 는 통제된 로컬 디버깅에서만 명시적으로
  사용하고 CI/공유 로그/프로덕션에서는 사용하지 마세요.
- **cURL 내보내기.** `URLRequest.curlCommand()` 는 기본적으로 요청 본문을 생략하고 모든 헤더와
  query 값을 redaction합니다. 실제 값이 꼭 필요할 때만 통제된 로컬 진단 경로에서
  `includesHeaderValues`, `includesQueryValues`, `includesBody` 를 각각 명시적으로 활성화하세요.
  URL user-info와 fragment는 opt-in 여부와 관계없이 내보내지 않습니다.
- **실패 페이로드 캡처.** `NetworkError.decoding(stage:, underlying:, response:)` 는 `Response` 를 함께 전달하지만,
  기본 설정에서는 `response.data` 가 빈 `Data` 로 redaction 됩니다.
  `NetworkConfiguration.captureFailurePayload = true` 로 명시적으로 활성화한 경우에만 원본 응답 본문이
  유지됩니다. PII 가 크래시 로그/분석에 남지 않도록 릴리즈 빌드에서는 비활성화 상태를 유지하세요.
- **이벤트 옵저버 부착.** `NetworkEventObserving` 옵저버는 앱 시작 시 부착하고 로그아웃 / 계정
  전환 시 분리합니다. 사용자 취소 이후 발생하는 이벤트도 옵저버는 모두 받습니다.

### 회복탄력성

- **로그아웃 시 cancel-all.** 로그아웃 / 계정 전환 / 백그라운딩 시 `DefaultNetworkClient.cancelAll()`
  을 호출합니다. `DefaultNetworkClient.stream` 이 등록한 스트리밍 요청(SSE/NDJSON)도
  in-flight registry를 통해 함께 취소되므로, 부모 task 취소만 기다리지 않아도 됩니다.
- **재시도 예산.** `ExponentialBackoffRetryPolicy.maxTotalRetries` 는 망복구로도 reset 되지 않는
  절대 한도입니다. 요청 단위가 아닌 사용자 세션 단위로 예산을 잡으세요.
- **인증 갱신.** `401` 이후 refresh + replay는 `ResponseInterceptor`가 아니라
  `RefreshTokenPolicy`로 설정합니다. 동시 refresh는 하나로 합쳐지고, interceptor 적용이 끝난
  요청 replay는 최대 1회만 수행됩니다.
- **캐시 / 회로 차단.** `ResponseCachePolicy`, `RequestCoalescingPolicy`,
  `CircuitBreakerPolicy`는 모두 opt-in입니다. API별 freshness와 host failure budget을 정한 뒤
  `NetworkConfiguration.advanced`에서 켜세요.
- **WebSocket 재연결 cap.** `maxReconnectAttempts` 가 자동 재시도 횟수를 제한합니다. 소진된
  이후에는 매 foreground 마다 재연결하지 말고 UI 로 실패를 노출하세요.

### Push / 라이프사이클

- **백그라운드 친화.** 스트리밍/웹소켓 product 는 앱 서스펜션 전에 명시적인 `disconnect()` 를
  기대합니다. `applicationDidEnterBackground` 정리 로직을 구현하세요. OS 가 소켓을 우아하게 닫지
  않습니다.
- **토큰 갱신.** 인증 갱신은 `RefreshTokenPolicy`로 설정하고, 동시 갱신은 클라이언트의
  single-flight coordination에 맡깁니다. 그렇지 않으면 동시 재시도가 갱신 엔드포인트를
  폭주시킵니다.

### 출시 전 스모크 테스트

| 영역 | 점검 |
|------|------|
| Trust | 잘못된 인증서로 핀된 호스트에 요청 → `NetworkError.trustEvaluationFailed` 확인 |
| Retry | `503 Retry-After: 30` 응답 stub → 정책이 헤더를 준수하는지 확인 |
| Background download | 다운로드 중 앱 강종료 → 재실행 시 `DownloadRestoreCoordinator` 가 복원 |
| WebSocket reconnect | 10초+ 망 단절 → 복구 시 설정 횟수만 시도하는지 확인 |
| Cancel-all | 스트림 + 업로드 in-flight 상태에서 `cancelAll()` → 둘 다 `.cancelled` 로 종료 |

---

## 문서

- DocC API Reference: https://innosquadcorp.github.io/InnoNetwork/
- 영문 README: [../../README.md](../../README.md)
- 예제: [../../Examples/README.md](../../Examples/README.md)
- API 안정성: [../../API_STABILITY.md](../../API_STABILITY.md)
- 클라이언트 아키텍처: [../ClientArchitecture.md](../ClientArchitecture.md)
- 릴리즈 정책: [../RELEASE_POLICY.md](../RELEASE_POLICY.md)
- 마이그레이션 정책: [../MIGRATION_POLICY.md](../MIGRATION_POLICY.md)
- 5.0 마이그레이션 초안: [../Migration-5.0.0.md](../Migration-5.0.0.md)
- 5.0 릴리즈 노트 초안: [../releases/5.0.0.md](../releases/5.0.0.md)
- 로드맵: [../ROADMAP.md](../ROADMAP.md)

## 라이선스

MIT. 자세한 내용은 [LICENSE](../../LICENSE) 를 참고하세요.
