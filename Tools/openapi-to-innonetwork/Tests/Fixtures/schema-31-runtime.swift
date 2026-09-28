import Foundation
import InnoNetwork
import os

private final class ModernURLProtocol: URLProtocol {
    static let captured = OSAllocatedUnfairLock(initialState: [Data]())
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 64)
            while true {
                let count = stream.read(&buffer, maxLength: buffer.count)
                precondition(count >= 0)
                if count == 0 { break }
                body.append(contentsOf: buffer.prefix(count))
            }
        }
        let capturedBody = body
        let index = Self.captured.withLock { values in
            values.append(capturedBody)
            return values.count
        }
        client?.urlProtocol(
            self,
            didReceive: HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"]
            )!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: index == 1 ? body : Data("0".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main struct ModernSchemaFixture {
    static func main() async throws {
        let data = Data("2.000".utf8)
        let choice = try PreservedJSONCoding.decode(ModernChoice.self, from: data)
        let bytes = try PreservedJSONCoding.encode(choice)
        precondition(choice.matchingBranches == [0, 1] && bytes == data)
        let null = try ModernChoice(json: PreservedJSON(data: Data("null".utf8)))
        precondition(null.matchingBranches == [0])
        _ = try Anything(json: PreservedJSON(data: Data("null".utf8)))
        _ = try AboveOne(json: PreservedJSON(data: data))
        do {
            _ = try AboveOne(json: PreservedJSON(data: Data("1".utf8)))
            preconditionFailure("Reference sibling constraint was dropped")
        } catch JSONProcessingError.noMatchingSchema {}
        do {
            _ = try Nothing(json: PreservedJSON(data: data))
            preconditionFailure("False schema accepted a value")
        } catch JSONProcessingError.noMatchingSchema {}
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ModernURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = DefaultNetworkClient(
            configuration: .safeDefaults(baseURL: URL(string: "https://example.com")!), session: session)
        let returned = try await client.request(SendModern(parameters: choice))
        precondition(returned.json.data == data && returned.matchingBranches == [0, 1])
        do {
            _ = try await client.request(SendModern(parameters: choice))
            preconditionFailure("Invalid server response bypassed 3.1 validation")
        } catch NetworkError.decoding {}
        precondition(ModernURLProtocol.captured.withLock { $0 } == [data, data])
        print("OpenAPI 3.1 subset runtime: boolean, type/null, ref siblings and exact bytes passed")
    }
}
