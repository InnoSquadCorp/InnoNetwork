# InnoNetwork — 한국어

[English](README.md) · [한국어](README.ko.md) · [Español](README.es.md) · [Deutsch](README.de.md) · [简体中文](README.zh-Hans.md) · [日本語](README.ja.md) · [Русский](README.ru.md)

InnoNetwork는 Apple 플랫폼의 타입 안전한 비동기 네트워킹 라이브러리입니다. 명시적인 endpoint 구조체, `@APIDefinition`, `DefaultNetworkClient.request`로 시작하세요. 선택 기능을 위해 처음부터 모든 제품을 연결할 필요는 없습니다.

## 현재 버전과 범위

최신 안정 버전은 **6.1.1**이며 2026-10-07 UTC에 공개되었습니다. 이 패치는 6.1.0 대비 런타임·공개 API 변경 없이 문서와 도구를 수정합니다. 태그 revision은 `44e4ca28c50c03f817231a077c0f3bdfdbc859c8`입니다. 일곱 언어의 현재 안내는 같은 설치·예제·계약 범위를 다루며, 상세 영문 설명은 [README](README.md)에 있습니다.

[6.1.1 Release](https://github.com/InnoSquadCorp/InnoNetwork/releases/tag/6.1.1) · [Release notes](docs/releases/6.1.1.md)

## 요구 사항과 설치

Swift **6.2+**, Swift 6 언어 모드가 필요합니다. 지원 하한은 iOS **16**, macOS **14**, tvOS **16**, watchOS **9**, visionOS **1**입니다. Apple 전용이며 Linux는 지원하지 않습니다. 아래 두 선언을 각각 패키지와 target 의존성에 넣으세요.

```swift
// Package.swift — dependencies
.package(
    url: "https://github.com/InnoSquadCorp/InnoNetwork.git",
    .upToNextMinor(from: "6.1.1")
)

// Package.swift — target dependencies
.product(name: "InnoNetwork", package: "InnoNetwork")
```

재현성이 필요하면 `.exact("6.1.1")`을 사용하세요. 패치 범위는 Provisionally Stable API의 새 minor 변경을 자동 채택하지 않도록 합니다. `Package.resolved`의 실제 버전을 확인하세요. 기본 `Macros` trait를 끄려면 패키지 의존성에 `traits: []`을 추가하고 프로토콜을 직접 구현합니다. 모든 의존 경로에서 trait가 꺼져야 합니다. SwiftPM은 SwiftSyntax 등 manifest 의존성을 여전히 해석하거나 가져올 수 있습니다.

## 제품 선택

- `InnoNetwork` — 타입 안전한 HTTP 요청과 정책 파이프라인

- `InnoNetworkAuthAWS` — 선택형 AWS SigV4 단일 요청 서명; AWS SDK 대체물이 아님

- `InnoNetworkDownload` — 다운로드, 일시 중지·재개, 백그라운드 복원, 이벤트

- `InnoNetworkUpload` — 파일 기반 업로드, 진행률, 복원, 크기가 제한된 응답

- `InnoNetworkWebSocket` — 양방향 연결, heartbeat, 재연결, 종료 분류

- `InnoNetworkPersistentCache` — RFC 인식 디스크 캐시와 저장소 제한

- `InnoNetworkOpenAPI` — 전체 client 파이프라인 adapter 또는 얇은 OpenAPI Runtime transport

- `InnoNetworkTrust` — 선택형 공개키 pinning evaluator

- `InnoNetworkTestSupport` — 소비자 테스트 전용 helper; 프로덕션 target에 연결하지 않음

`InnoNetworkMacroSupport`는 컴파일러 호스트 전용입니다. HLS는 별도 [InnoNetwork-Stream](https://github.com/InnoSquadCorp/InnoNetwork-Stream), Protobuf는 별도 [InnoNetwork-Protobuf](https://github.com/InnoSquadCorp/InnoNetwork-Protobuf)에 있습니다. 둘의 6.1.1은 Core 6.1.1을 정확히 고정합니다. Stream의 모듈은 `InnoNetworkHLS`, `InnoNetworkHLSLive`, `InnoNetworkHLSAVFoundation`, `InnoNetworkHLSAudio`이며 `InnoNetworkStream` 모듈은 없습니다. Audio는 Swift 6.4 및 OS 27 가용성 조건이 있습니다. Protobuf의 선호 product는 `InnoNetwork-Protobuf`, import 모듈은 `InnoNetworkProtobuf`입니다.

## 첫 번째 요청

예제 서버는 설명용입니다. 실제 서버 URL과 응답 모델을 사용하고 async 문맥에서 실행하세요. 구조체가 입력과 `APIResponse`의 기준이며 macro가 반복 conformance를 생성합니다. `.anonymous`, `.optional`, `.required` 중 인증 경계를 반드시 명시합니다. GET/HEAD는 저장된 `query`, POST/PUT/PATCH/DELETE는 `body`를 추론합니다. 다른 메서드나 사용자 payload에는 완전한 `Parameter`/`parameters` 계약이 필요합니다.

```swift
import Foundation
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

let client = DefaultNetworkClient(
    baseURL: URL(string: "https://api.example.com/v1")!
)
let user = try await client.request(GetUser(id: 42))
print(user.name)
```

## 설정·인증·보안

`DefaultNetworkClient(baseURL:)`은 `NetworkConfiguration.safeDefaults(baseURL:)`와 같은 경로입니다. 서버 계약이 요구할 때만 configuration pack을 추가하세요. path는 base URL 뒤에 붙고 `?`·`#`를 포함하면 안 됩니다. query는 encoder를 거칩니다. HTTPS와 기본 redaction을 유지하고 토큰·본문을 로그에 쓰지 마세요. 캐시는 모든 응답을 저장하지 않으며 `no-store`, `Vary`, 인증된 응답의 저장 허용 조건을 따릅니다. `Expires`와 `Last-Modified` fallback도 무제한 저장을 의미하지 않습니다.

## 오류와 재시도

`request`와 `upload`는 `NetworkError`를 던집니다. 취소, 상태 코드, 디코딩, 설정, 신뢰 평가 실패를 구분하세요. 아래 오류 예제는 종료하지 않은 client에서 독립적으로 실행합니다. GET/HEAD/OPTIONS/TRACE가 기본 재시도 대상이고, 변경 요청 재실행에는 서버의 멱등성 보장이 필요합니다. 401은 조정된 refresh를 허용할 수 있지만 403은 자동 refresh·replay 신호가 아닙니다.

```swift
do {
    let user = try await client.request(GetUser(id: 42))
    print(user.name)
} catch {
    switch error {
    case .cancelled:
        print("Cancelled")
    case .statusCode(let response):
        print(response.statusCode)
    default:
        print(error)
    }
}
```

## 작업 소유권과 종료

작업 예제는 기존 request 예제와 별도로 실행합니다. `value()`는 payload를 보존하지 않는 `NetworkFailure`를 던집니다. `value()`를 기다리는 task를 취소하면 operation에도 취소가 전달됩니다. 명시적 취소가 필요하면 handle을 보관하세요. 예제의 `cancel()`은 소유자가 더 이상 작업을 원하지 않을 때 호출할 API이며, 완료 후 호출은 이미 받은 결과를 되돌리지 않습니다. 이벤트는 bounded 시작·종료 상태이고 결과는 `value()`로 받습니다. 이벤트 iterator를 버리는 것만으로 모든 작업이 취소된다고 가정하지 마세요.

```swift
let operations = OperationNetworkClient(client: client)
let operation = operations.start(GetUser(id: 42))
do {
    let user = try await operation.value()
    print(user.name)
} catch {
    print(error) // NetworkFailure
}
// Owner: call operation.cancel() when in-flight work is no longer needed.
await client.shutdown()
```

`cancelAll()`은 진행 중 작업을 취소하지만 client는 재사용할 수 있습니다. `shutdown()`은 멱등적이며 최종 종료입니다. 작업·refresh를 취소하고 소유한 session만 무효화하며, 이후 요청은 `.cancelled`로 실패합니다. 주입한 session은 호출자가 소유합니다. Download/Upload/WebSocket manager를 기능 수명 동안 유지하고 고유 background session ID와 복원 barrier를 사용하세요. WebSocket 명시적 retry는 새 논리 task와 이벤트 stream을 반환합니다. operation마다 생성되는 자동 멱등 키는 새 operation 사이에서 동일하지 않습니다.

## 마이그레이션

5.x에서는 [6.0 마이그레이션](docs/Migration-6.0.0.md), 이어서 [6.1 encoded request](docs/Migration-EncodedRequests.md)를 적용하세요. `InnoNetworkNext`를 제거하고 `InnoNetwork`를 import합니다. HLS target의 package 소유자를 `InnoNetwork-Stream`으로 바꾸되 기존 HLS import 이름은 유지합니다. JSON macro는 바뀌지 않으며 binary codec에는 공개 `EncodedRequest` 경계를 사용합니다. 6.1.0에서 6.1.1로는 새 소스 마이그레이션이 없습니다. 이전 major별 안내는 역사적 계약을 설명합니다.

## 검증과 문서

이 번역의 예제는 소스 대조와 정적 검사를 대상으로 합니다. Swift 빌드·DocC 렌더링·실제 장치 또는 원어민 감수를 수행했다는 뜻은 아닙니다. 지원되는 Apple 환경에서 아래 검사를 실행하고, 앱의 실제 서비스·백그라운드 복원·인증·취소 동작을 별도로 확인하세요. 스킬의 기존 exact 6.1.0 테스트 기록은 모든 후속 패치의 검증 증거가 아닙니다.

```bash
swift test
bash Scripts/check_docs_contract_sync.sh
swift build --target InnoNetworkDocSmoke
```

[API Stability](API_STABILITY.md) · [Examples](Examples/README.md) · [DocC](https://innosquadcorp.github.io/InnoNetwork/)

[Task ownership](docs/TaskOwnership.md) · [WebSocket lifecycle](docs/WebSocketLifecycle.md) · [Policy interactions](docs/PolicyInteractions.md)

[Contributing](CONTRIBUTING.md) · [Security](SECURITY.md) · [Support](SUPPORT.md) · [Release policy](docs/RELEASE_POLICY.md) · [Agent skill](skills/README.md) · [MIT License](LICENSE)

[이전 한국어 문서 (역사 자료)](docs/ko/README.md)
