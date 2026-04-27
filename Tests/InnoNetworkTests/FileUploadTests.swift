import Foundation
import os
import Testing
@testable import InnoNetwork


/// MockURLSession-equivalent that *also* honors `upload(for:fromFile:)` so
/// the tests below can verify the executor reaches the streaming-upload
/// path when given a `RequestPayload.fileURL`.
private final class FileAwareMockSession: URLSessionProtocol, Sendable {
    private struct State {
        var responseData: Data
        var statusCode: Int
        var capturedFileURL: URL?
        var capturedFileBytes: Data?
        var capturedRequest: URLRequest?
    }

    private let lock: OSAllocatedUnfairLock<State>

    init(statusCode: Int = 200, responseData: Data = Data("{}".utf8)) {
        self.lock = OSAllocatedUnfairLock(initialState: State(
            responseData: responseData,
            statusCode: statusCode,
            capturedFileURL: nil,
            capturedFileBytes: nil,
            capturedRequest: nil
        ))
    }

    var capturedFileURL: URL? { lock.withLock { $0.capturedFileURL } }
    var capturedFileBytes: Data? { lock.withLock { $0.capturedFileBytes } }
    var capturedRequest: URLRequest? { lock.withLock { $0.capturedRequest } }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let snapshot = lock.withLock { state -> (Data, Int) in
            state.capturedRequest = request
            return (state.responseData, state.statusCode)
        }
        return (snapshot.0, HTTPURLResponse(
            url: request.url ?? URL(string: "https://example.com")!,
            statusCode: snapshot.1,
            httpVersion: nil,
            headerFields: nil
        )!)
    }

    func upload(for request: URLRequest, fromFile fileURL: URL, context: NetworkRequestContext) async throws -> (Data, URLResponse) {
        let bytes = try Data(contentsOf: fileURL)
        let snapshot = lock.withLock { state -> (Data, Int) in
            state.capturedRequest = request
            state.capturedFileURL = fileURL
            state.capturedFileBytes = bytes
            return (state.responseData, state.statusCode)
        }
        return (snapshot.0, HTTPURLResponse(
            url: request.url ?? URL(string: "https://example.com")!,
            statusCode: snapshot.1,
            httpVersion: nil,
            headerFields: nil
        )!)
    }
}


private struct UploadFromFileExecutable: SingleRequestExecutable {
    typealias APIResponse = EchoResponse

    let fileURL: URL
    let contentType: String

    var logger: NetworkLogger { NoOpNetworkLogger() }
    var requestInterceptors: [RequestInterceptor] { [] }
    var responseInterceptors: [ResponseInterceptor] { [] }
    var method: HTTPMethod { .post }
    var path: String { "/upload" }
    var headers: HTTPHeaders { HTTPHeaders() }

    func makePayload() throws -> RequestPayload {
        .fileURL(fileURL, contentType: contentType)
    }

    func decode(data: Data, response: Response) throws -> EchoResponse {
        EchoResponse(byteCount: data.count)
    }
}


private struct EchoResponse: Sendable, Equatable {
    let byteCount: Int
}


@Suite("File Upload Tests")
struct FileUploadTests {

    @Test("RequestPayload.fileURL routes through URLSessionProtocol.upload(for:fromFile:)")
    func fileUploadRoutesThroughUploadPath() async throws {
        // Spool a multipart body to a temp file.
        let payloadURL = FileManager.default.temporaryDirectory.appendingPathComponent("upload-payload-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: payloadURL) }
        var formData = MultipartFormData(boundary: "upload-test-boundary")
        formData.append(Data(repeating: 0x42, count: 1024), name: "blob", fileName: "blob.bin", mimeType: "application/octet-stream")
        try formData.writeEncodedData(to: payloadURL)

        let session = FileAwareMockSession()
        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(baseURL: "https://api.example.com/v1"),
            session: session
        )

        let executable = UploadFromFileExecutable(
            fileURL: payloadURL,
            contentType: formData.contentTypeHeader
        )
        _ = try await client.perform(executable: executable)

        // The session received the file URL and the bytes match what we
        // wrote to disk earlier.
        #expect(session.capturedFileURL == payloadURL)
        let captured = try #require(session.capturedFileBytes)
        let expected = try Data(contentsOf: payloadURL)
        #expect(captured == expected)
        // Content-Type was overridden by the .fileURL contentType.
        #expect(session.capturedRequest?.value(forHTTPHeaderField: "Content-Type") == formData.contentTypeHeader)
    }

    @Test("Upload via in-memory MockURLSession surfaces a clear unsupported error")
    func uploadOnNonUploadingSessionThrows() async throws {
        let payloadURL = FileManager.default.temporaryDirectory.appendingPathComponent("upload-noop-\(UUID().uuidString).bin")
        try Data("payload".utf8).write(to: payloadURL)
        defer { try? FileManager.default.removeItem(at: payloadURL) }

        let session = MockURLSession()
        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(baseURL: "https://api.example.com/v1"),
            session: session
        )
        let executable = UploadFromFileExecutable(
            fileURL: payloadURL,
            contentType: "application/octet-stream"
        )

        await #expect(throws: NetworkError.self) {
            _ = try await client.perform(executable: executable)
        }
    }
}
