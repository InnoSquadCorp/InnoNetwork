# 시작하기

안전한 기본값으로 클라이언트를 만들고, ``APIDefinition`` 으로 요청을 모델링한
다음 ``DefaultNetworkClient`` 를 통해 호출하는 방법을 설명합니다.

> 한국어 번역본 (영문 원본 → <doc:GettingStarted>) 입니다. 두 문서의 내용이
> 일치하지 않을 때는 영문 원본의 정의를 우선합니다.

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

`safeDefaults(baseURL:)` 는 4.x 의 권장 출발점입니다. 재시도, 회로 차단기,
RFC 9111 호환 캐시 어댑터, redaction 정책이 모두 합리적인 디폴트로 설정되어
있어 호출부에서 별도 튜닝 없이 시작할 수 있습니다.

## 요청 정의

```swift
import InnoNetwork

struct User: Decodable, Sendable {
    let id: Int
    let name: String
}

struct GetUser: APIDefinition {
    typealias Parameter = EmptyParameter
    typealias APIResponse = User

    var method: HTTPMethod { .get }
    var path: String { "/users/1" }
}
```

`APIDefinition` 은 InnoNetwork 의 1차 시민 요청 모델입니다. 응답 타입을
`APIResponse` 에 명시하면 ``NetworkClient/request(_:)`` 가 그 타입으로
디코딩한 결과를 그대로 반환합니다.

## 요청 실행

```swift
let user = try await client.request(GetUser())
print(user.name)
```

`request(_:)` 는 `async throws(NetworkError)` 시그니처로 선언되어 있으므로
오류는 항상 ``NetworkError`` 로만 전파됩니다. typed throws 덕분에 별도의
`as NetworkError` 캐스팅 없이 `do/catch` 블록에서 곧바로 case 별 분기로
처리할 수 있습니다.

## 간단한 호출은 `EndpointBuilder` 사용

요청이 메서드, 경로, 쿼리/바디 파라미터, 헤더, 컨텐츠 타입, 허용 status code,
응답 디코딩만 필요하다면 ``EndpointBuilder`` 가 더 가볍습니다.

```swift
let users = try await client.request(
    EndpointBuilder<EmptyResponse, PublicAuthScope>
        .get("/users")
        .query(["limit": 20])
        .decoding([User].self)
)
```

엔드포인트가 자체 인터셉터, 별도 인코더/디코더, multipart 업로드, 스트리밍을
가져야 한다면 전용 ``APIDefinition`` 구조체를 유지하세요.

엔드포인트 경로는 설정된 base URL 의 경로 뒤에 그대로 이어붙여집니다. 슬래시(`/`)
로 시작하더라도 base URL 의 경로는 보존되며, 쿼리는 `parameters`/``URLQueryEncoder``
나 ``EndpointBuilder/query(_:)`` 에서 표현해야 합니다. 경로에 직접 `?` 나 `#` 가
들어 있으면 ``NetworkError/configuration(reason:)`` 으로 거부됩니다.

## 요청 실행 계약

일반 요청은 ``NetworkClient/request(_:)``, multipart 업로드는
``NetworkClient/upload(_:)`` 만 사용하세요. 그 외의 저수준 실행 훅은 4.0.0 의
안정 공개 표면이 아니며, 향후 통합 후보로만 간주합니다.

## 고급 설정으로 전환할 때

다음 중 하나가 필요할 때만 ``NetworkConfiguration/safeDefaults(baseURL:)`` 에서
``NetworkConfiguration/advanced(baseURL:resilience:auth:observability:cache:transport:)`` 로 옮기는 것을 권장합니다.

- 재시도 정책의 의미 변경
- TLS 신뢰 평가 동작 변경
- 이벤트 전달 정책 변경
- 메트릭/관측 가능성(observability) 리포터 추가

위 항목 이외의 튜닝은 가능한 한 안전한 기본값 위에서 endpoint 단위로 조정하는
편이 향후 마이너 릴리스의 변경 면적을 줄입니다.
