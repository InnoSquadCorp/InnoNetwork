import Foundation
@_spi(GeneratedClientSupport) import InnoNetwork
import Testing
import os

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
        var capturedAllowsAutomaticRedirects: Bool?
        var capturedAllowsURLCacheStorage: Bool?
    }

    private let lock: OSAllocatedUnfairLock<State>

    init(statusCode: Int = 200, responseData: Data = Data("{}".utf8)) {
        self.lock = OSAllocatedUnfairLock(
            initialState: State(
                responseData: responseData,
                statusCode: statusCode,
                capturedFileURL: nil,
                capturedFileBytes: nil,
                capturedRequest: nil,
                capturedAllowsAutomaticRedirects: nil,
                capturedAllowsURLCacheStorage: nil
            ))
    }

    var capturedFileURL: URL? { lock.withLock { $0.capturedFileURL } }
    var capturedFileBytes: Data? { lock.withLock { $0.capturedFileBytes } }
    var capturedRequest: URLRequest? { lock.withLock { $0.capturedRequest } }
    var capturedAllowsAutomaticRedirects: Bool? { lock.withLock { $0.capturedAllowsAutomaticRedirects } }
    var capturedAllowsURLCacheStorage: Bool? { lock.withLock { $0.capturedAllowsURLCacheStorage } }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let snapshot = lock.withLock { state -> (Data, Int) in
            state.capturedRequest = request
            return (state.responseData, state.statusCode)
        }
        return (
            snapshot.0,
            HTTPURLResponse(
                url: request.url ?? URL(string: "https://example.com")!,
                statusCode: snapshot.1,
                httpVersion: nil,
                headerFields: nil
            )!
        )
    }

    func upload(for request: URLRequest, fromFile fileURL: URL, context: NetworkRequestContext) async throws -> (
        Data, URLResponse
    ) {
        let bytes = try Data(contentsOf: fileURL)
        let snapshot = lock.withLock { state -> (Data, Int) in
            state.capturedRequest = request
            state.capturedAllowsAutomaticRedirects = context.allowsAutomaticRedirects
            state.capturedAllowsURLCacheStorage = context.allowsURLCacheStorage
            state.capturedFileURL = fileURL
            state.capturedFileBytes = bytes
            return (state.responseData, state.statusCode)
        }
        return (
            snapshot.0,
            HTTPURLResponse(
                url: request.url ?? URL(string: "https://example.com")!,
                statusCode: snapshot.1,
                httpVersion: nil,
                headerFields: nil
            )!
        )
    }
}


private enum FileUploadPayloadStrategy: Sendable {
    case file
    case temporaryFile

    func makePayload(fileURL: URL, contentType: String) -> RequestPayload {
        switch self {
        case .file:
            return .fileURL(fileURL, contentType: contentType)
        case .temporaryFile:
            return .temporaryFileURL(fileURL, contentType: contentType)
        }
    }
}


private struct FileUploadTestExecutable: SingleRequestExecutable {
    typealias APIResponse = EchoResponse

    let fileURL: URL
    let contentType: String
    let payloadStrategy: FileUploadPayloadStrategy

    var logger: NetworkLogger { NoOpNetworkLogger() }
    var requestInterceptors: [RequestInterceptor] { [] }
    var responseInterceptors: [ResponseInterceptor] { [] }
    var method: HTTPMethod { .post }
    var path: String { "/upload" }
    var headers: HTTPHeaders { HTTPHeaders() }

    func makePayload() throws -> RequestPayload {
        payloadStrategy.makePayload(fileURL: fileURL, contentType: contentType)
    }

    func decode(data: Data, response: Response) throws -> EchoResponse {
        EchoResponse(byteCount: data.count)
    }
}


private struct EchoResponse: Sendable, Equatable {
    let byteCount: Int
}


private struct FileMutationSigner: RequestSigner {
    let callerURL: URL
    let replacement: Data

    func signatureHeaders(for request: URLRequest, body: RequestBody) async throws -> HTTPHeaders {
        _ = request
        guard case .file(let snapshotURL) = body else {
            throw NetworkError.configuration(reason: .invalidRequest("Expected a file signing body."))
        }
        let snapshotBytes = try Data(contentsOf: snapshotURL)
        try replacement.write(to: callerURL, options: .atomic)
        return ["X-Snapshot-Bytes": snapshotBytes.base64EncodedString()]
    }
}


private struct IntentionalSignerFailure: Error, Sendable {}


private final class SigningBodyURLRecorder: Sendable {
    private let lock = OSAllocatedUnfairLock<URL?>(initialState: nil)

    func record(_ url: URL) { lock.withLock { $0 = url } }
    var url: URL? { lock.withLock { $0 } }
}


private struct ThrowingFileSigner: RequestSigner {
    let recorder: SigningBodyURLRecorder

    func signatureHeaders(for request: URLRequest, body: RequestBody) async throws -> HTTPHeaders {
        _ = request
        if case .file(let fileURL) = body {
            recorder.record(fileURL)
        }
        throw IntentionalSignerFailure()
    }
}


private actor BlockingFileSigner: RequestSigner {
    private var bodyURL: URL?
    private var didStart = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    func signatureHeaders(for request: URLRequest, body: RequestBody) async throws -> HTTPHeaders {
        _ = request
        if case .file(let fileURL) = body {
            bodyURL = fileURL
        }
        didStart = true
        let pending = startWaiters
        startWaiters.removeAll()
        pending.forEach { $0.resume() }
        try await Task.sleep(for: .seconds(60))
        return [:]
    }

    func waitUntilStarted() async {
        guard !didStart else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    var capturedBodyURL: URL? { bodyURL }
}


private struct InvalidGETTemporaryFileExecutable: SingleRequestExecutable {
    typealias APIResponse = EchoResponse

    let fileURL: URL
    var logger: NetworkLogger { NoOpNetworkLogger() }
    var requestInterceptors: [RequestInterceptor] { [] }
    var responseInterceptors: [ResponseInterceptor] { [] }
    var method: HTTPMethod { .get }
    var path: String { "/invalid-upload" }
    var headers: HTTPHeaders { HTTPHeaders() }

    func makePayload() throws -> RequestPayload {
        .temporaryFileURL(fileURL, contentType: "application/octet-stream")
    }

    func decode(data: Data, response: Response) throws -> EchoResponse {
        EchoResponse(byteCount: data.count)
    }
}


@Suite("File Upload Tests")
struct FileUploadTests {

    @Test("RequestPayload.fileURL routes through URLSessionProtocol.upload(for:fromFile:)")
    func fileUploadRoutesThroughUploadPath() async throws {
        // Spool a multipart body to a temp file.
        let payloadURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "upload-payload-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: payloadURL) }
        var formData = MultipartFormData(boundary: "upload-test-boundary")
        formData.append(
            Data(repeating: 0x42, count: 1024), name: "blob", fileName: "blob.bin", mimeType: "application/octet-stream"
        )
        try formData.writeEncodedData(to: payloadURL)

        let session = FileAwareMockSession()
        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(baseURL: "https://api.example.com/v1"),
            session: session
        )

        let executable = FileUploadTestExecutable(
            fileURL: payloadURL,
            contentType: formData.contentTypeHeader,
            payloadStrategy: .file
        )
        _ = try await client.perform(executable: executable)

        // The session received the file URL and the bytes match what we
        // wrote to disk earlier.
        #expect(session.capturedFileURL == payloadURL)
        let captured = try #require(session.capturedFileBytes)
        let expected = try Data(contentsOf: payloadURL)
        #expect(captured == expected)
        #expect(FileManager.default.fileExists(atPath: payloadURL.path))
        #expect(session.capturedAllowsAutomaticRedirects == true)
        #expect(session.capturedAllowsURLCacheStorage == true)
        // Content-Type was overridden by the .fileURL contentType.
        #expect(session.capturedRequest?.value(forHTTPHeaderField: "Content-Type") == formData.contentTypeHeader)
    }

    @Test("RequestPayload.temporaryFileURL is deleted after successful upload")
    func temporaryUploadFileIsDeletedAfterSuccess() async throws {
        let payloadURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "upload-temp-success-\(UUID().uuidString).bin")
        let payload = Data("temporary upload body".utf8)
        try payload.write(to: payloadURL)
        defer { try? FileManager.default.removeItem(at: payloadURL) }

        let session = FileAwareMockSession()
        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(baseURL: "https://api.example.com/v1"),
            session: session
        )
        let executable = FileUploadTestExecutable(
            fileURL: payloadURL,
            contentType: "application/octet-stream",
            payloadStrategy: .temporaryFile
        )

        _ = try await client.perform(executable: executable)

        #expect(session.capturedFileURL == payloadURL)
        #expect(session.capturedFileBytes == payload)
        #expect(!FileManager.default.fileExists(atPath: payloadURL.path))
    }

    @Test("RequestPayload.temporaryFileURL is deleted after failed upload")
    func temporaryUploadFileIsDeletedAfterFailure() async throws {
        let payloadURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "upload-temp-failure-\(UUID().uuidString).bin")
        let payload = Data("temporary upload body".utf8)
        try payload.write(to: payloadURL)
        defer { try? FileManager.default.removeItem(at: payloadURL) }

        let session = FileAwareMockSession(statusCode: 500, responseData: Data("server error".utf8))
        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(baseURL: "https://api.example.com/v1"),
            session: session
        )
        let executable = FileUploadTestExecutable(
            fileURL: payloadURL,
            contentType: "application/octet-stream",
            payloadStrategy: .temporaryFile
        )

        do {
            _ = try await client.perform(executable: executable)
            Issue.record("Expected NetworkError.statusCode(500)")
        } catch let error as NetworkError {
            guard case .statusCode(let response) = error else {
                Issue.record("Expected NetworkError.statusCode(500), got \(error)")
                return
            }
            #expect(response.statusCode == 500)
        } catch {
            Issue.record("Expected NetworkError.statusCode(500), got \(error)")
        }

        #expect(session.capturedFileURL == payloadURL)
        #expect(session.capturedFileBytes == payload)
        #expect(!FileManager.default.fileExists(atPath: payloadURL.path))
    }

    @Test("Upload via in-memory MockURLSession surfaces a clear unsupported error")
    func uploadOnNonUploadingSessionThrows() async throws {
        let payloadURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "upload-noop-\(UUID().uuidString).bin")
        try Data("payload".utf8).write(to: payloadURL)
        defer { try? FileManager.default.removeItem(at: payloadURL) }

        let session = MockURLSession()
        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(baseURL: "https://api.example.com/v1"),
            session: session
        )
        let executable = FileUploadTestExecutable(
            fileURL: payloadURL,
            contentType: "application/octet-stream",
            payloadStrategy: .file
        )

        do {
            _ = try await client.perform(executable: executable)
            Issue.record("Expected NetworkError.invalidRequestConfiguration")
        } catch let error as NetworkError {
            guard case .configuration(reason: .invalidRequest(let message)) = error else {
                Issue.record("Expected NetworkError.invalidRequestConfiguration, got \(error)")
                return
            }
            #expect(message.contains("File-based upload is not supported"))
        } catch {
            Issue.record("Expected NetworkError.invalidRequestConfiguration, got \(error)")
        }
    }

    @Test("Signed caller file uses one private snapshot for hashing and upload")
    func signedCallerFileUsesStableSnapshot() async throws {
        let callerURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "signed-caller-\(UUID().uuidString).bin"
        )
        let original = Data("original wire bytes".utf8)
        let replacement = Data("mutated after signing".utf8)
        try original.write(to: callerURL)
        defer { try? FileManager.default.removeItem(at: callerURL) }

        let session = FileAwareMockSession()
        let signer = FileMutationSigner(callerURL: callerURL, replacement: replacement)
        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(
                baseURL: "https://api.example.com/v1",
                requestSigners: [signer]
            ),
            session: session
        )

        _ = try await client.perform(
            executable: FileUploadTestExecutable(
                fileURL: callerURL,
                contentType: "application/octet-stream",
                payloadStrategy: .file
            )
        )

        let snapshotURL = try #require(session.capturedFileURL)
        #expect(snapshotURL != callerURL)
        #expect(session.capturedFileBytes == original)
        #expect(
            session.capturedRequest?.value(forHTTPHeaderField: "X-Snapshot-Bytes") == original.base64EncodedString())
        #expect(try Data(contentsOf: callerURL) == replacement)
        #expect(FileManager.default.fileExists(atPath: callerURL.path))
        #expect(!FileManager.default.fileExists(atPath: snapshotURL.path))
        #expect(session.capturedAllowsAutomaticRedirects == false)
        #expect(session.capturedAllowsURLCacheStorage == false)
        #expect(session.capturedRequest?.cachePolicy == .reloadIgnoringLocalCacheData)
        #expect(session.capturedRequest?.value(forHTTPHeaderField: "Cache-Control") == "no-store")
    }

    @Test("Caller snapshot is removed when a signer throws without removing the caller file")
    func callerSnapshotCleansUpAfterSignerFailure() async throws {
        let callerURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "signer-failure-caller-\(UUID().uuidString).bin"
        )
        try Data("caller-owned".utf8).write(to: callerURL)
        defer { try? FileManager.default.removeItem(at: callerURL) }
        let recorder = SigningBodyURLRecorder()
        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(
                baseURL: "https://api.example.com/v1",
                requestSigners: [ThrowingFileSigner(recorder: recorder)]
            ),
            session: FileAwareMockSession()
        )

        await #expect(throws: NetworkError.self) {
            _ = try await client.perform(
                executable: FileUploadTestExecutable(
                    fileURL: callerURL,
                    contentType: "application/octet-stream",
                    payloadStrategy: .file
                )
            )
        }

        let snapshotURL = try #require(recorder.url)
        #expect(snapshotURL != callerURL)
        #expect(!FileManager.default.fileExists(atPath: snapshotURL.path))
        #expect(FileManager.default.fileExists(atPath: callerURL.path))
    }

    @Test("Library temporary file is removed when a signer throws")
    func temporaryFileCleansUpAfterSignerFailure() async throws {
        let temporaryURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "signer-failure-temporary-\(UUID().uuidString).bin"
        )
        try Data("library-owned".utf8).write(to: temporaryURL)
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        let recorder = SigningBodyURLRecorder()
        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(
                baseURL: "https://api.example.com/v1",
                requestSigners: [ThrowingFileSigner(recorder: recorder)]
            ),
            session: FileAwareMockSession()
        )

        await #expect(throws: NetworkError.self) {
            _ = try await client.perform(
                executable: FileUploadTestExecutable(
                    fileURL: temporaryURL,
                    contentType: "application/octet-stream",
                    payloadStrategy: .temporaryFile
                )
            )
        }

        #expect(recorder.url == temporaryURL)
        #expect(!FileManager.default.fileExists(atPath: temporaryURL.path))
    }

    @Test("Caller snapshot is removed when signing is cancelled")
    func callerSnapshotCleansUpAfterSignerCancellation() async throws {
        let callerURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "signer-cancel-caller-\(UUID().uuidString).bin"
        )
        try Data("caller-owned".utf8).write(to: callerURL)
        defer { try? FileManager.default.removeItem(at: callerURL) }
        let signer = BlockingFileSigner()
        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(
                baseURL: "https://api.example.com/v1",
                requestSigners: [signer]
            ),
            session: FileAwareMockSession()
        )
        let executable = FileUploadTestExecutable(
            fileURL: callerURL,
            contentType: "application/octet-stream",
            payloadStrategy: .file
        )

        let task = Task { try await client.perform(executable: executable) }
        await signer.waitUntilStarted()
        let snapshotURL = try #require(await signer.capturedBodyURL)
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Expected signing cancellation")
        } catch {
            #expect(NetworkError.isCancellation(error))
        }

        #expect(!FileManager.default.fileExists(atPath: snapshotURL.path))
        #expect(FileManager.default.fileExists(atPath: callerURL.path))
    }

    @Test("Builder removes a temporary payload when validation fails before preparation returns")
    func builderScopeCleansTemporaryPayload() async throws {
        let temporaryURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "builder-failure-temporary-\(UUID().uuidString).bin"
        )
        try Data("temporary".utf8).write(to: temporaryURL)
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(baseURL: "https://api.example.com/v1"),
            session: FileAwareMockSession()
        )

        await #expect(throws: NetworkError.self) {
            _ = try await client.perform(
                executable: InvalidGETTemporaryFileExecutable(fileURL: temporaryURL)
            )
        }

        #expect(!FileManager.default.fileExists(atPath: temporaryURL.path))
    }
}
