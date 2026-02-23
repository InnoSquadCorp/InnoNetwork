# InnoNetwork

A Swift package for type-safe network communication using async/await and Swift Concurrency.

## Project Overview

InnoNetwork는 async/await 기반의 타입-세이프 Swift 네트워크 라이브러리입니다. Swift Concurrency(Actor, Sendable)를 활용하여 스레드 안전한 요청/응답 처리를 제공합니다.

> v2 마이그레이션 가이드는 `MIGRATION_v2.md`를 참고하세요.

## Features

### Core
- **Async/await 기반 API 요청** - Swift Concurrency 네이티브 지원
- **타입 안전한 요청/응답 처리** - Generic을 통한compile-time 타입 체크
- **모든 HTTP 메서드 지원** - GET, POST, PUT, PATCH, DELETE
- **멀티플랫폼 지원** - iOS, macOS, tvOS, watchOS, visionOS
- **Sendable 완전 준수** - Swift 6.2 Concurrency Checker 통과

### Advanced
- **요청/응답 인터셉터** - 요청 수정 및 응답 처리
- **자동 재시도 로직** - 커스텀 RetryPolicy 지원
- **설정 가능한 타임아웃 및 캐싱**
- **Actor 기반 API 정의** - 스레드 안전성 보장
- **Trust Policy / Public Key Pinning** - 시스템 기본 신뢰 + 핀닝 옵션
- **Lifecycle 관측 이벤트** - request start/finish/retry/failure 이벤트 제공

### Content Types
- **JSON** - 기본 콘텐츠 타입
- **Form URL-encoded** - 폼 데이터 인코딩 (배열, 중첩 객체 지원)
- **Multipart/Form-data** - 파일 업로드 지원

### Download Module (별도 모듈)
- **백그라운드 다운로드** - 앱 종료 후에도 다운로드 지속
- **일시정지/재개** - resumeData를 통한 다운로드 재개
- **자동 재시도** - 실패한 다운로드 자동 재시도
- **AsyncSequence 이벤트 스트림** - Swift Concurrency 네이티브 이벤트 수신

### WebSocket Module (별도 모듈)
- **자동 heartbeat/pong timeout** - 운영 상태 모니터링
- **자동 reconnect + jitter** - 장애 상황 복구 내장
- **멀티 리스너 이벤트 스트림** - task 단위 구독 지원

## Requirements

- Swift 6.2+
- iOS 26.0+ / macOS 26.0+ / tvOS 26.0+ / watchOS 26.0+ / visionOS 26.0+

## Installation

### InnoNetwork (Core)
```swift
dependencies: [
    .package(url: "https://github.com/InnoSquad/InnoNetwork.git", from: "2.0.0")
]
```

### InnoNetworkDownload (다운로드 기능)
```swift
dependencies: [
    .product(name: "InnoNetworkDownload", package: "InnoNetwork")
]
```

## Quick Start

```swift
import InnoNetwork

// API 설정
struct MyAPI: APIConfigure {
    var host: String { "https://api.example.com" }
    var basePath: String { "v1" }
}

// 클라이언트 생성
let client = try DefaultNetworkClient(configuration: MyAPI())
```

`host`는 스킴(`https://`)을 포함한 값을 기본값으로 사용하세요.
호스트 문자열만 사용하는 경우에는 `baseURL`을 명시적으로 override하세요.

## Core Concepts

### Actor-based API Definitions

모든 API 엔드포인트는 `APIDefinition` 프로토콜을 준수하는 struct 또는 actor로 정의합니다:

```swift
struct GetUser: APIDefinition {
    typealias Parameter = EmptyParameter
    typealias APIResponse = User

    var method: HTTPMethod { .get }
    var path: String { "/user/1" }
}

// 사용
let user = try await client.request(GetUser())
```

### Making Requests

```swift
do {
    let user = try await client.request(GetUser())
    print(user)
} catch {
    print("Error: \(error)")
}
```

## Usage Examples

### Basic Setup

```swift
import InnoNetwork

struct MyAPI: APIConfigure {
    var host: String { "https://api.example.com" }
    var basePath: String { "v1" }
}

let client = try DefaultNetworkClient(configuration: MyAPI())
```

```swift
struct LegacyStyleAPI: APIConfigure {
    var host: String { "api.example.com" }
    var basePath: String { "v1" }
    var baseURL: URL? { URL(string: "https://api.example.com/v1") }
}
```

### Request with Parameters

```swift
struct CreatePost: APIDefinition {
    struct PostParameter: Encodable, Sendable {
        let title: String
        let body: String
        let userId: Int
    }

    typealias Parameter = PostParameter
    typealias APIResponse = Post

    let parameters: PostParameter?
    var method: HTTPMethod { .post }
    var path: String { "/posts" }

    init(title: String, body: String, userId: Int = 1) {
        self.parameters = PostParameter(title: title, body: body, userId: userId)
    }
}

// 사용
let newPost = try await client.request(CreatePost(
    title: "My New Post",
    body: "This is the content"
))
```

### Form URL-encoded

```swift
struct LoginRequest: APIDefinition {
    struct LoginParameter: Encodable, Sendable {
        let email: String
        let password: String
    }

    typealias Parameter = LoginParameter
    typealias APIResponse = AuthResponse

    let parameters: LoginParameter?
    var method: HTTPMethod { .post }
    var path: String { "/login" }
    var contentType: ContentType { .formUrlEncoded }

    init(email: String, password: String) {
        self.parameters = LoginParameter(email: email, password: password)
    }
}
```

### Multipart/Form-data (파일 업로드)

```swift
struct UploadImage: MultipartAPIDefinition {
    typealias APIResponse = UploadResponse

    var multipartFormData: MultipartFormData {
        var formData = MultipartFormData()
        formData.append("My Image", name: "title")
        formData.append(
            imageData,
            name: "file",
            fileName: "image.jpg",
            mimeType: "image/jpeg"
        )
        return formData
    }

    var method: HTTPMethod { .post }
    var path: String { "/upload" }
}

// 사용
let response = try await client.upload(UploadImage())
```

### Download (별도 모듈)

```swift
import InnoNetworkDownload

let manager = DownloadManager.shared

// 다운로드 시작
let task = await manager.download(
    url: URL(string: "https://example.com/file.zip")!,
    toDirectory: documentsDirectory
)

// 이벤트 스트림으로 진행 상황 수신
for await event in manager.events(for: task) {
    switch event {
    case .progress(let progress):
        print("Progress: \(progress.percentCompleted)%")
    case .completed(let url):
        print("Downloaded to: \(url)")
    case .failed(let error):
        print("Failed: \(error)")
    default:
        break
    }
}

// 일시정지/재개
await manager.pause(task)
await manager.resume(task)
```

리스너 생명주기 규칙:
- retry/reconnect 동안 기존 `events(for:)` / `addEventListener` 구독은 유지됩니다.
- terminal 상태(`completed`, 명시적 `cancel`, 최종 `failed`)에서만 리스너가 정리됩니다.

### Advanced Configuration

```swift
// 커스텀 재시도 정책 정의
struct MyRetryPolicy: RetryPolicy {
    let maxRetries: Int = 3
    let maxTotalRetries: Int = 6
    let retryDelay: TimeInterval = 2.0

    func shouldRetry(error: NetworkError, retryIndex: Int) -> Bool {
        guard retryIndex < maxRetries else { return false }

        switch error {
        case .statusCode(let response):
            return [500, 502, 503, 504].contains(response.statusCode)
        case .underlying(let underlyingError, _):
            return underlyingError.domain == NSURLErrorDomain
                && [
                    URLError.timedOut.rawValue,
                    URLError.notConnectedToInternet.rawValue,
                    URLError.networkConnectionLost.rawValue
                ].contains(underlyingError.code)
        default:
            return false
        }
    }
}

// 네트워크 설정
let networkConfig = NetworkConfiguration(
    baseURL: URL(string: "https://api.example.com")!,
    timeout: 30.0,
    cachePolicy: .useProtocolCachePolicy,
    retryPolicy: MyRetryPolicy(),
    trustPolicy: .publicKeyPinning(
        PublicKeyPinningPolicy(
            pinsByHost: [
                "api.example.com": [
                    "sha256/PRIMARY_PIN_BASE64",
                    "sha256/BACKUP_PIN_BASE64"
                ]
            ],
            includesSubdomains: true,
            allowDefaultEvaluationForUnpinnedHosts: true
        )
    ),
    eventObservers: [OSLogNetworkEventObserver()]
)

let client = try DefaultNetworkClient(
    configuration: MyAPI(),
    networkConfiguration: networkConfig
)
```

### Trust & Pinning

```swift
let trustPolicy: TrustPolicy = .publicKeyPinning(
    PublicKeyPinningPolicy(
        pinsByHost: [
            "api.example.com": [
                "sha256/PRIMARY_PIN_BASE64",
                "sha256/BACKUP_PIN_BASE64"
            ]
        ],
        includesSubdomains: true,
        allowDefaultEvaluationForUnpinnedHosts: true
    )
)
```

### Observability Events

```swift
struct EventObserver: NetworkEventObserving {
    func handle(_ event: NetworkEvent) {
        print("Network event: \(event)")
    }
}

let networkConfig = NetworkConfiguration(
    baseURL: URL(string: "https://api.example.com")!,
    eventObservers: [EventObserver()]
)
```

`eventObservers`는 요청 경로를 막지 않도록 비동기(best-effort)로 전달됩니다.
관측 로직은 빠르게 반환하도록 구현하는 것을 권장합니다.

### Interceptors

요청 및 응답 인터셉터를 사용하여 요청/응답을 수정할 수 있습니다:

```swift
// 요청 인터셉터
struct AuthInterceptor: RequestInterceptor {
    func adapt(_ urlRequest: URLRequest) async throws -> URLRequest {
        var urlRequest = urlRequest
        urlRequest.setValue("Bearer token", forHTTPHeaderField: "Authorization")
        return urlRequest
    }
}

// 응답 인터셉터
struct LoggingResponseInterceptor: ResponseInterceptor {
    func adapt(_ urlResponse: Response, request: URLRequest) async throws -> Response {
        print("Response: \(urlResponse.statusCode)")
        return urlResponse
    }
}

// 인터셉터 사용
struct GetProfile: APIDefinition {
    typealias Parameter = EmptyParameter
    typealias APIResponse = Profile

    var method: HTTPMethod { .get }
    var path: String { "/profile" }

    var requestInterceptors: [RequestInterceptor] {
        [AuthInterceptor()]
    }

    var responseInterceptors: [ResponseInterceptor] {
        [LoggingResponseInterceptor()]
    }
}
```

### Custom Headers

```swift
struct GetPosts: APIDefinition {
    typealias Parameter = EmptyParameter
    typealias APIResponse = [Post]

    var method: HTTPMethod { .get }
    var path: String { "/posts" }

    var headers: HTTPHeaders {
        var customHeaders = HTTPHeaders.default
        customHeaders.add(.acceptLanguage("ko-KR,ko;q=0.9,en-US;q=0.8"))
        customHeaders.add(.userAgent("MyApp/1.0.0"))
        return customHeaders
    }
}
```

### Error Handling

```swift
do {
    let response = try await client.request(MyAPIRequest())
    print("Success: \(response)")
} catch let error as NetworkError {
    switch error {
    case .invalidBaseURL(let url):
        print("Invalid URL: \(url)")
    case .statusCode(let response):
        print("HTTP Error: \(response.statusCode)")
    case .objectMapping(let decodingError, _):
        print("Decoding Error: \(decodingError)")
    case .underlying(let underlyingError, _):
        print("Network Error: \(underlyingError.domain) (\(underlyingError.code))")
    case .trustEvaluationFailed(let reason):
        print("Trust Evaluation Failed: \(reason)")
    case .cancelled:
        print("Request was cancelled")
    default:
        print("Unknown error: \(error)")
    }
}
```

## API Reference

### Protocols

#### APIConfigure

기본 API 설정을 정의합니다:

```swift
public protocol APIConfigure: Sendable {
    var host: String { get }
    var basePath: String { get }
    var baseURL: URL? { get }
}
```

#### APIDefinition

단일 API 엔드포인트를 정의합니다:

```swift
public protocol APIDefinition: Sendable {
    associatedtype Parameter: Encodable & Sendable
    associatedtype APIResponse: Decodable & Sendable

    var parameters: Parameter? { get }
    var method: HTTPMethod { get }
    var path: String { get }
    var contentType: ContentType { get }
    var decoder: JSONDecoder { get }
    var headers: HTTPHeaders { get }
    var logger: NetworkLogger { get }
    var requestInterceptors: [RequestInterceptor] { get }
    var responseInterceptors: [ResponseInterceptor] { get }
}
```

#### MultipartAPIDefinition

파일 업로드를 위한 멀티파트 요청을 정의합니다:

```swift
public protocol MultipartAPIDefinition: Sendable {
    associatedtype APIResponse: Decodable & Sendable
    var multipartFormData: MultipartFormData { get }
    var method: HTTPMethod { get }
    var path: String { get }
    // ... other properties
}
```

#### NetworkClient

API 요청을 수행하는 클라이언트입니다:

```swift
public protocol NetworkClient: Sendable {
    func request<T: APIDefinition>(_ request: T) async throws -> T.APIResponse
    func upload<T: MultipartAPIDefinition>(_ request: T) async throws -> T.APIResponse
}
```

#### NetworkConfiguration

```swift
public struct NetworkConfiguration: Sendable {
    public let baseURL: URL
    public let timeout: TimeInterval
    public let cachePolicy: URLRequest.CachePolicy
    public let retryPolicy: (any RetryPolicy)?
    public let networkMonitor: (any NetworkMonitoring)?
    public let metricsReporter: (any NetworkMetricsReporting)?
    public let trustPolicy: TrustPolicy
    public let eventObservers: [any NetworkEventObserving]
}
```

### Download Module (InnoNetworkDownload)

#### DownloadManager

다운로드를 관리합니다:

```swift
public final class DownloadManager: Sendable {
    public static let shared = DownloadManager()
    
    // 다운로드 시작
    public func download(url: URL, to destinationURL: URL) async -> DownloadTask
    public func download(url: URL, toDirectory directory: URL, fileName: String? = nil) async -> DownloadTask
    
    // 다운로드 제어
    public func pause(_ task: DownloadTask) async
    public func resume(_ task: DownloadTask) async
    public func cancel(_ task: DownloadTask) async
    public func cancelAll() async
    public func retry(_ task: DownloadTask) async
    
    // 이벤트 스트림
    public func events(for task: DownloadTask) -> AsyncStream<DownloadEvent>
    public func addEventListener(
        for task: DownloadTask,
        listener: @escaping @Sendable (DownloadEvent) -> Void
    ) async -> DownloadEventSubscription
    public func removeEventListener(_ subscription: DownloadEventSubscription) async
    
    // 권장 콜백 등록 API (race-free)
    public func setOnProgressHandler(
        _ callback: (@Sendable (DownloadTask, DownloadProgress) async -> Void)?
    ) async
    public func setOnStateChangedHandler(
        _ callback: (@Sendable (DownloadTask, DownloadState) async -> Void)?
    ) async
    public func setOnCompletedHandler(
        _ callback: (@Sendable (DownloadTask, URL) async -> Void)?
    ) async
    public func setOnFailedHandler(
        _ callback: (@Sendable (DownloadTask, DownloadError) async -> Void)?
    ) async
}
```

리스너는 retry 동안 유지되며, `completed`/`cancel`/최종 `failed`에서 정리됩니다.

#### DownloadEvent

이벤트 스트림을 통해 수신되는 이벤트:

```swift
public enum DownloadEvent: Sendable {
    case progress(DownloadProgress)
    case stateChanged(DownloadState)
    case completed(URL)
    case failed(DownloadError)
}
```

#### WebSocketManager

```swift
public final class WebSocketManager: Sendable {
    public static let shared = WebSocketManager()

    public func connect(url: URL, subprotocols: [String]? = nil) async -> WebSocketTask
    // Can be called while task is connected, connecting, or reconnecting
    public func disconnect(_ task: WebSocketTask, closeCode: URLSessionWebSocketTask.CloseCode = .normalClosure) async
    public func disconnectAll(closeCode: URLSessionWebSocketTask.CloseCode = .normalClosure) async

    public func send(_ task: WebSocketTask, message: Data) async throws
    public func send(_ task: WebSocketTask, string: String) async throws
    public func ping(_ task: WebSocketTask) async throws

    // Returns after listener registration completes (no initial event loss window).
    public func events(for task: WebSocketTask) async -> AsyncStream<WebSocketEvent>
    public func addEventListener(
        for task: WebSocketTask,
        listener: @escaping @Sendable (WebSocketEvent) -> Void
    ) async -> WebSocketEventSubscription
    public func removeEventListener(_ subscription: WebSocketEventSubscription) async

    // 권장 콜백 등록 API (race-free)
    public func setOnConnectedHandler(_ callback: (@Sendable (WebSocketTask, String?) async -> Void)?) async
    public func setOnDisconnectedHandler(_ callback: (@Sendable (WebSocketTask, WebSocketError?) async -> Void)?) async
    public func setOnMessageHandler(_ callback: (@Sendable (WebSocketTask, Data) async -> Void)?) async
    public func setOnStringHandler(_ callback: (@Sendable (WebSocketTask, String) async -> Void)?) async
    public func setOnErrorHandler(_ callback: (@Sendable (WebSocketTask, WebSocketError) async -> Void)?) async

    // WebSocketManager does not use a background URLSession.
    // This callback is invoked immediately for compatibility.
    public func handleBackgroundSessionCompletion(_ identifier: String, completion: @escaping @Sendable () -> Void)
}
```

리스너는 auto-reconnect 동안 유지되며, 명시적 `disconnect` 또는 최종 실패 시 정리됩니다.
`WebSocketEvent.disconnected`는 close reason이 존재할 때
`WebSocketError.disconnected(SendableUnderlyingError)` 형태로 reason을 전달합니다.

#### WebSocketConfiguration

```swift
public struct WebSocketConfiguration: Sendable {
    public let heartbeatInterval: TimeInterval
    public let pongTimeout: TimeInterval
    public let maxMissedPongs: Int
    public let reconnectJitterRatio: Double
    public let maxReconnectAttempts: Int
    // Reserved for compatibility; WebSocketManager currently uses default URLSession configuration.
    public let sessionIdentifier: String
    // ... existing session fields
}
```

`maxReconnectAttempts`는 "재연결 횟수" 의미이며, 총 연결 시도 수는 `1 + maxReconnectAttempts`입니다.

## Error Types

InnoNetwork는 다음 에러 타입을 제공합니다:

- `NetworkError.invalidBaseURL`: 유효하지 않은 base URL
- `NetworkError.nonHTTPResponse`: HTTPURLResponse 아님
- `NetworkError.statusCode`: HTTP 상태 코드가 200-299 범위 밖
- `NetworkError.objectMapping`: Decodable 객체로 매핑 실패
- `NetworkError.underlying`: 하부 네트워크 에러 (URLError 등)
- `NetworkError.cancelled`: 요청이 취소됨

## Building & Testing

```bash
# 빌드
swift build

# 테스트 실행
swift test

# 외부 네트워크 통합 테스트 포함 실행
INNONETWORK_RUN_INTEGRATION_TESTS=1 swift test

# 테스트 및 코드 커버리지
swift test --enable-code-coverage --parallel

# 특정 테스트 실행
swift test --filter InnoNetworkTests
```

## Examples

`Examples/` 디렉토리에서 포괄적인 예제를 확인하세요:

- **BasicRequest**: 기본 HTTP 메서드 (GET, POST, PUT, PATCH, DELETE)
- **ErrorHandling**: 에러 처리 패턴 및 디버깅
- **CustomHeaders**: 커스텀 헤더 사용 및 인증
- **RealWorldAPI**: 실제 앱 시나리오 (CRUD, 페이지네이션, 배치 처리)

각 예제 디렉토리에는 README가 포함되어 있습니다.

## Architecture

```
InnoNetwork/
├── Sources/
│   ├── InnoNetwork/              # Core (REST API)
│   │   ├── API.swift             # APIConfigure 프로토콜
│   │   ├── APIDefinition.swift   # APIDefinition, MultipartAPIDefinition
│   │   ├── DefaultNetworkClient.swift  # NetworkClient 구현
│   │   ├── Model/
│   │   │   ├── MultipartFormData.swift
│   │   │   ├── EmptyParameter.swift
│   │   │   ├── EmptyResponse.swift
│   │   │   └── Response.swift
│   │   └── ... (interceptors, error, logger 등)
│
│   ├── InnoNetworkDownload/      # Download 모듈 (별도 product)
│   │   ├── DownloadManager.swift
│   │   ├── DownloadTask.swift    # actor 기반 다운로드 작업
│   │   ├── DownloadConfiguration.swift
│   │   ├── DownloadState.swift
│   │   ├── DownloadSessionDelegate.swift
│   │   └── DownloadTaskPersistence.swift
│
│   └── InnoNetworkWebSocket/     # WebSocket 모듈 (별도 product)
│       ├── WebSocketManager.swift
│       ├── WebSocketTask.swift
│       ├── WebSocketConfiguration.swift
│       └── WebSocketSessionDelegate.swift
│
└── Tests/
    ├── InnoNetworkTests/
    ├── InnoNetworkDownloadTests/
    └── InnoNetworkWebSocketTests/
```

## CI and DoC

- GitHub Actions CI: `.github/workflows/ci.yml`
- Definition of Completion (DoC): `docs/CI_DoC.md`
- DocC GitHub Pages deployment: `.github/workflows/docc-pages.yml`
- DocC 운영 가이드: `docs/DocC_Deployment.md`

## License

MIT License

Copyright (c) 2025 InnoSquad.
