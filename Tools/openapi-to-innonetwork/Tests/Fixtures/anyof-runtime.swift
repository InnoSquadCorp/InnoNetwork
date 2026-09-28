import Foundation
import InnoNetwork
import os

private let rawChoice = Data(
    #"{"id":7,"name":"both","unknown":123456789012345678901234567890123456789012345678901234567890.000e9999}"#.utf8)

private func require(_ condition: @autoclosure () throws -> Bool) throws {
    let passed = try condition()
    precondition(passed)
}

private struct FixtureProvider: RequestCredentialProvider {
    func select(alternatives: [[RequestSecurity.Scheme]], origin: URL) -> RequestSecurity.Selection {
        .init(alternative: 0, realm: "fixture", principal: "test")
    }
    func credential(for scheme: RequestSecurity.Scheme, selection: RequestSecurity.Selection, origin: URL)
        -> RequestSecurity.Credential
    {
        .init(value: "fixture-key", realm: selection.realm, principal: selection.principal)
    }
}

private final class AnyOfURLProtocol: URLProtocol {
    static let captured = OSAllocatedUnfairLock(initialState: [URLRequest]())
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let capturedRequest = request
        Self.captured.withLock { $0.append(capturedRequest) }
        let body: Data
        switch request.url!.path {
        case "/choice": body = rawChoice
        case "/envelope":
            body =
                Data("{\"value\":".utf8) + rawChoice + Data(",\"list\":[".utf8) + rawChoice
                + Data(#"],"createdAt":"2001-01-01T00:00:42.000Z"}"#.utf8)
        case "/accepted": body = Data()
        default: body = Data("{}".utf8)
        }
        client?.urlProtocol(
            self,
            didReceive: HTTPURLResponse(
                url: request.url!, statusCode: body.isEmpty ? 204 : 200,
                httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main
struct GeneratedAnyOfSmoke {
    static func main() async throws {
        let choice = try Choice(json: PreservedJSON(data: rawChoice))
        precondition(choice.matchingBranches == [0, 1])
        let identifier = try choice.asBranch0()
        let label = try choice.asBranch1()
        precondition(identifier?.id == 7 && label?.name == "both")
        try require(try PreservedJSONCoding.encode(choice) == rawChoice)
        let one = try Choice(json: PreservedJSON(data: Data(#"{"id":1}"#.utf8)))
        precondition(one.matchingBranches == [0])
        try require(try one.asBranch1() == nil)
        do {
            _ = try Choice(json: PreservedJSON(data: Data("{}".utf8)))
            fatalError("Zero matches accepted")
        } catch JSONProcessingError.noMatchingSchema {}
        do {
            _ = try JSONEncoder().encode(choice)
            fatalError("Foundation silently encoded preserved JSON")
        } catch JSONProcessingError.unsupportedCoder {}
        let huge = Data("123456789012345678901234567890123456789012345678901234567890".utf8)
        let numeric = try NumericChoice(json: PreservedJSON(data: huge))
        precondition(numeric.matchingBranches == [0, 1])
        try require(try PreservedJSONCoding.encode(numeric) == huge)
        do {
            _ = try numeric.asBranch0()
            fatalError("Out-of-range typed view accepted")
        } catch is DecodingError {}
        try require(try NumericChoice(json: PreservedJSON(data: Data("0.5".utf8))).matchingBranches == [1])

        let origin = URL(string: "https://api.example.com")!
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AnyOfURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = DefaultNetworkClient(configuration: .safeDefaults(baseURL: origin), session: session)
        let returned = try await client.request(
            SendChoice(credentialOrigin: origin, credentialProvider: FixtureProvider(), parameters: choice))
        precondition(returned.json.data == rawChoice && returned.matchingBranches == [0, 1])
        let envelope = try await client.request(ReadEnvelope())
        precondition(envelope.value == choice && envelope.list == [choice])
        precondition(envelope.createdAt == Date(timeIntervalSinceReferenceDate: 42))
        let encodedEnvelope = try PreservedJSONCoding.encode(envelope)
        try require(try PreservedJSONCoding.decode(ChoiceEnvelope.self, from: encodedEnvelope) == envelope)
        _ = try await client.request(AcceptChoice(parameters: one))
        do {
            _ = try await client.request(InvalidChoice())
            fatalError("Invalid response accepted")
        } catch NetworkError.decoding {}
        let requests = AnyOfURLProtocol.captured.withLock { $0 }
        precondition(requests.count == 4)
        precondition(requests[0].value(forHTTPHeaderField: "X-Fixture-Key") == "fixture-key")
        precondition(requests[0].value(forHTTPHeaderField: "Content-Type")?.contains("application/json") == true)
        // URLSession may expose the request body as an input stream to URLProtocol.
        var body = requests[0].httpBody
        if body == nil, let stream = requests[0].httpBodyStream {
            stream.open()
            defer { stream.close() }
            var bytes = [UInt8](repeating: 0, count: 1024)
            var result = Data()
            while true {
                let count = stream.read(&bytes, maxLength: bytes.count)
                precondition(count >= 0)
                if count == 0 { break }
                result.append(contentsOf: bytes.prefix(count))
            }
            body = result
        }
        precondition(body == rawChoice)
        print("Generated anyOf runtime passed (4 requests, zero/one/multiple matches, nested wire fidelity).")
    }
}
