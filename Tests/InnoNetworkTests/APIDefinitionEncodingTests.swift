import Foundation
import Testing

@testable import InnoNetwork

private struct EncodingPayload: Encodable, Sendable {
    let userName: String
    let createdAt: Date
}

private struct CustomEmptyResponse: HTTPEmptyResponseDecodable, Equatable {
    let marker: String

    init(marker: String = "factory") {
        self.marker = marker
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.marker = try container.decode(String.self)
    }

    static func emptyResponseValue() -> Self {
        Self()
    }
}

private func makeShortDateFormatter() -> DateFormatter {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    return formatter
}

private struct CustomJSONEncodingRequest: APIDefinition {
    typealias Parameter = EncodingPayload
    typealias APIResponse = EmptyResponse

    let parameters: EncodingPayload?

    var method: HTTPMethod { .post }
    var path: String { "/encoding/json" }

    var requestEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .formatted(makeShortDateFormatter())
        return encoder
    }
}

private struct CustomQueryEncodingRequest: APIDefinition {
    typealias Parameter = EncodingPayload
    typealias APIResponse = EmptyResponse

    let parameters: EncodingPayload?

    var method: HTTPMethod { .get }
    var path: String { "/encoding/query" }

    var queryEncoder: URLQueryEncoder {
        URLQueryEncoder(
            keyEncodingStrategy: URLQueryKeyEncodingStrategy.convertToSnakeCase,
            dateEncodingStrategy: .formatted(makeShortDateFormatter())
        )
    }
}

private struct CustomFormEncodingRequest: APIDefinition {
    typealias Parameter = EncodingPayload
    typealias APIResponse = EmptyResponse

    let parameters: EncodingPayload?

    var method: HTTPMethod { .post }
    var path: String { "/encoding/form" }
    var contentType: ContentType { .formUrlEncoded }

    var queryEncoder: URLQueryEncoder {
        URLQueryEncoder(
            keyEncodingStrategy: URLQueryKeyEncodingStrategy.convertToSnakeCase,
            dateEncodingStrategy: .formatted(makeShortDateFormatter())
        )
    }
}

private struct MisconfiguredMultipartRequest: APIDefinition {
    typealias Parameter = EncodingPayload
    typealias APIResponse = EmptyResponse

    let parameters: EncodingPayload?

    var method: HTTPMethod { .post }
    var path: String { "/encoding/misconfigured-multipart" }
    var contentType: ContentType { .multipartFormData }
}

private struct TopLevelArrayQueryRequest: APIDefinition {
    typealias Parameter = [String]
    typealias APIResponse = EmptyResponse

    let parameters: [String]?

    var method: HTTPMethod { .get }
    var path: String { "/encoding/array-query" }
    var queryRootKey: String? { "tags" }
}

private struct MissingTopLevelArrayQueryRootKeyRequest: APIDefinition {
    typealias Parameter = [String]
    typealias APIResponse = EmptyResponse

    let parameters: [String]?

    var method: HTTPMethod { .get }
    var path: String { "/encoding/array-query" }
}

private struct TopLevelScalarFormRequest: APIDefinition {
    typealias Parameter = String
    typealias APIResponse = EmptyResponse

    let parameters: String?

    var method: HTTPMethod { .post }
    var path: String { "/encoding/scalar-form" }
    var contentType: ContentType { .formUrlEncoded }
    var queryRootKey: String? { "query" }
}

private struct MissingTopLevelScalarFormRootKeyRequest: APIDefinition {
    typealias Parameter = String
    typealias APIResponse = EmptyResponse

    let parameters: String?

    var method: HTTPMethod { .post }
    var path: String { "/encoding/scalar-form" }
    var contentType: ContentType { .formUrlEncoded }
}

private struct DictionaryQueryRequest: APIDefinition {
    typealias Parameter = [String: Int]
    typealias APIResponse = EmptyResponse

    let parameters: [String: Int]?

    var method: HTTPMethod { .get }
    var path: String { "/encoding/dictionary" }
}

private struct SnakeCaseProbe: Encodable {
    let key: String

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: AnyCodingKey.self)
        try container.encode("value", forKey: AnyCodingKey(key))
    }
}

private struct CustomEmptyRequest: APIDefinition {
    typealias Parameter = EmptyParameter
    typealias APIResponse = CustomEmptyResponse

    var method: HTTPMethod { .delete }
    var path: String { "/encoding/empty" }
}


@Suite("Encoder Configuration Tests")
struct APIDefinitionEncodingTests {
    private let configuration = makeTestNetworkConfiguration(baseURL: "https://example.com")
    private let payload = EncodingPayload(
        userName: "Alice",
        createdAt: Date(timeIntervalSince1970: 1_734_393_600)
    )

    @Test("Custom requestEncoder shapes JSON request bodies")
    func customRequestEncoderShapesJSONBody() async throws {
        let mockSession = MockURLSession()
        mockSession.setMockResponse(statusCode: 204)
        let client = DefaultNetworkClient(configuration: configuration, session: mockSession)

        _ = try await client.request(CustomJSONEncodingRequest(parameters: payload))

        let body = try #require(mockSession.capturedRequest?.httpBody)
        let object = try #require(
            JSONSerialization.jsonObject(with: body) as? [String: String]
        )
        #expect(object["user_name"] == "Alice")
        #expect(object["created_at"] == "2024-12-17")
    }

    @Test("Custom queryEncoder shapes GET query strings")
    func customQueryEncoderShapesURLQuery() async throws {
        let mockSession = MockURLSession()
        mockSession.setMockResponse(statusCode: 204)
        let client = DefaultNetworkClient(configuration: configuration, session: mockSession)

        _ = try await client.request(CustomQueryEncodingRequest(parameters: payload))

        let url = try #require(mockSession.capturedRequest?.url)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let items = try #require(components.queryItems)
        #expect(items.contains { $0.name == "user_name" && $0.value == "Alice" })
        #expect(items.contains { $0.name == "created_at" && $0.value == "2024-12-17" })
    }

    @Test("Custom queryEncoder shapes form-urlencoded bodies")
    func customQueryEncoderShapesFormBody() async throws {
        let mockSession = MockURLSession()
        mockSession.setMockResponse(statusCode: 204)
        let client = DefaultNetworkClient(configuration: configuration, session: mockSession)

        _ = try await client.request(CustomFormEncodingRequest(parameters: payload))

        let body = try #require(mockSession.capturedRequest?.httpBody)
        let bodyString = try #require(String(data: body, encoding: .utf8))
        #expect(bodyString.contains("user_name=Alice"))
        #expect(bodyString.contains("created_at=2024-12-17"))
    }

    @Test("Multipart content type on APIDefinition throws invalid request configuration")
    func multipartContentTypeOnAPIDefinitionThrowsInvalidRequestConfiguration() async {
        let mockSession = MockURLSession()
        let client = DefaultNetworkClient(configuration: configuration, session: mockSession)

        do {
            let _: EmptyResponse = try await client.request(
                MisconfiguredMultipartRequest(parameters: payload)
            )
            Issue.record("Expected invalidRequestConfiguration for multipart APIDefinition")
        } catch let error as NetworkError {
            guard case .invalidRequestConfiguration(let message) = error else {
                Issue.record("Expected invalidRequestConfiguration, got \(error)")
                return
            }
            #expect(message.contains("MultipartAPIDefinition"))
            #expect(mockSession.capturedRequest == nil)
        } catch {
            Issue.record("Expected NetworkError, got \(error)")
        }
    }

    @Test("Empty responses use protocol-based factory without force casts")
    func customEmptyResponseUsesFactory() async throws {
        let mockSession = MockURLSession()
        mockSession.setMockResponse(statusCode: 204)
        let client = DefaultNetworkClient(configuration: configuration, session: mockSession)

        let response = try await client.request(CustomEmptyRequest())
        #expect(response == CustomEmptyResponse(marker: "factory"))
    }

    @Test("Top-level array query parameters require queryRootKey")
    func topLevelArrayQueryParametersRequireRootKey() async {
        let mockSession = MockURLSession()
        let client = DefaultNetworkClient(configuration: configuration, session: mockSession)

        await #expect(throws: NetworkError.self) {
            _ = try await client.request(
                MissingTopLevelArrayQueryRootKeyRequest(parameters: ["swift", "network"])
            )
        }
    }

    @Test("Top-level array query parameters use queryRootKey")
    func topLevelArrayQueryParametersUseRootKey() async throws {
        let mockSession = MockURLSession()
        mockSession.setMockResponse(statusCode: 204)
        let client = DefaultNetworkClient(configuration: configuration, session: mockSession)

        _ = try await client.request(
            TopLevelArrayQueryRequest(parameters: ["swift", "network"])
        )

        let url = try #require(mockSession.capturedRequest?.url)
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(items.map(\.name) == ["tags[0]", "tags[1]"])
    }

    @Test("Top-level scalar form parameters require queryRootKey")
    func topLevelScalarFormParametersRequireRootKey() async {
        let mockSession = MockURLSession()
        let client = DefaultNetworkClient(configuration: configuration, session: mockSession)

        await #expect(throws: NetworkError.self) {
            _ = try await client.request(
                MissingTopLevelScalarFormRootKeyRequest(parameters: "search")
            )
        }
    }

    @Test("Top-level scalar form parameters use queryRootKey")
    func topLevelScalarFormParametersUseRootKey() async throws {
        let mockSession = MockURLSession()
        mockSession.setMockResponse(statusCode: 204)
        let client = DefaultNetworkClient(configuration: configuration, session: mockSession)

        _ = try await client.request(TopLevelScalarFormRequest(parameters: "search"))

        let body = try #require(mockSession.capturedRequest?.httpBody)
        let bodyString = try #require(String(data: body, encoding: .utf8))
        #expect(bodyString == "query=search")
    }

    @Test("Dictionary query encoding is deterministic and sorted")
    func dictionaryQueryEncodingIsDeterministicAndSorted() throws {
        let queryItems = try URLQueryEncoder().encode(["b": 2, "a": 1])
        #expect(queryItems.map(\.name) == ["a", "b"])
        #expect(queryItems.map(\.value) == ["1", "2"])
    }

    @Test("Snake case query key strategy matches Foundation conversion for edge cases")
    func snakeCaseQueryKeyStrategyMatchesFoundation() throws {
        let encoder = URLQueryEncoder(keyEncodingStrategy: URLQueryKeyEncodingStrategy.convertToSnakeCase)
        let keys = [
            // Common camelCase
            "userID",
            "userId",
            "myProperty",
            "testCase",
            "isActive",

            // Acronym handling (run of uppercase)
            "URLValue",
            "HTMLURLValue",
            "myURLProperty",
            "getHTTPS",
            "JSONData",
            "useNSLogger",

            // Numbers in keys
            "value2Test",
            "version2API",
            "iOS18Build",
            "OAuth2Token",

            // Underscores at boundaries
            "_privateValue",
            "endsWith_",
            "_",
            "__doubleLeading",
            "trailing__",

            // Single character / very short
            "a",
            "A",
            "aB",
            "AB",

            // Already snake-case-ish
            "already_snake",
            "mixed_camelCase",

            // Trailing capital
            "valueX",
            "endsWithCapitalAB",

            // Numbers and capitals interleaved
            "ID123Value",
            "version1OfAPI",
        ]

        for key in keys {
            let expected = try foundationSnakeCaseKey(for: key)
            let actual = try #require(encoder.encode([key: "value"]).first?.name)
            #expect(actual == expected, "snake_case mismatch for key: \(key) — expected=\(expected) actual=\(actual)")
        }
    }

    private func foundationSnakeCaseKey(for key: String) throws -> String {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try encoder.encode(SnakeCaseProbe(key: key))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: String])
        return try #require(object.keys.first)
    }
}
