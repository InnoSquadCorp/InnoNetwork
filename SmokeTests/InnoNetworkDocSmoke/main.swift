import Foundation
import InnoNetwork
import InnoNetworkDownload
import InnoNetworkPersistentCache
import InnoNetworkWebSocket

private struct SmokeUser: Decodable, Sendable {
    let id: Int
    let name: String
}

private struct SmokeAuthResponse: Decodable, Sendable {
    let token: String
}

private struct SmokeGetUser: APIDefinition {
    typealias Parameter = EmptyParameter
    typealias APIResponse = SmokeUser

    var method: HTTPMethod { .get }
    var path: String { "/user/1" }
}

private struct SmokeLoginRequest: APIDefinition {
    struct Parameter: Encodable, Sendable {
        let email: String
        let password: String
    }

    typealias APIResponse = SmokeAuthResponse

    let parameters: Parameter?
    var method: HTTPMethod { .post }
    var path: String { "/login" }
    var contentType: ContentType { .formUrlEncoded }

    init(email: String, password: String) {
        self.parameters = Parameter(email: email, password: password)
    }
}

private struct SmokeUploadImage: MultipartAPIDefinition {
    typealias APIResponse = EmptyResponse

    let imageData: Data

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

private func compileBackgroundDownloadArticleExamples() async throws {
    let configuration = DownloadConfiguration.advanced(
        sessionIdentifier: "com.example.docsmoke.background.\(UUID().uuidString)"
    ) { builder in
        builder.allowsCellularAccess = true
        builder.maxConnectionsPerHost = 4
        builder.persistenceCompactionPolicy = .init(
            maxEvents: 1_000,
            maxLogBytes: 1_048_576,
            tombstoneRatio: 0.25
        )
    }

    let manager = try DownloadManager.make(configuration: configuration)
    _ = await manager.waitForRestoration()

    let task = await manager.download(
        url: URL(string: "https://example.com/archive.zip")!,
        to: FileManager.default.temporaryDirectory.appendingPathComponent("archive.zip")
    )
    await manager.pause(task)
    await manager.resume(task)
    await manager.cancel(task)
}

private func compileWebSocketArticleExamples() async {
    let configuration = WebSocketConfiguration.advanced { builder in
        builder.heartbeatInterval = 20
        builder.pongTimeout = 5
        builder.sendQueueLimit = 32
    }
    let manager = WebSocketManager(configuration: configuration)
    let task = await manager.connect(
        url: URL(string: "wss://echo.example.com/socket")!
    )
    let events = await manager.events(for: task)
    _ = events
    await manager.disconnect(task, closeCode: .custom(4001))
}

private func runDocSmoke() {
    let client = DefaultNetworkClient(
        configuration: .safeDefaults(
            baseURL: URL(string: "https://api.example.com/v1")!
        )
    )
    _ = client

    let networkAdvanced = NetworkConfiguration.advanced(
        baseURL: URL(string: "https://api.example.com/v1")!
    ) { builder in
        builder.timeout = 45
        builder.trustPolicy = .systemDefault
    }
    _ = networkAdvanced

    let production = NetworkConfiguration.recommendedForProduction(
        baseURL: URL(string: "https://api.example.com/v1")!
    )
    _ = production

    let persistentCacheConfiguration = PersistentResponseCacheConfiguration(
        directoryURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("innonetwork-docsmoke-cache", isDirectory: true)
    )
    _ = persistentCacheConfiguration

    let downloadDefaults = DownloadConfiguration.safeDefaults(
        sessionIdentifier: "com.example.docsmoke.downloads"
    )
    let downloadAdvanced = DownloadConfiguration.advanced { builder in
        builder.maxTotalRetries = 5
        builder.waitsForNetworkChanges = true
    }
    _ = downloadDefaults
    _ = downloadAdvanced

    let webSocketDefaults = WebSocketConfiguration.safeDefaults()
    let webSocketAdvanced = WebSocketConfiguration.advanced { builder in
        builder.heartbeatInterval = 15
        builder.maxReconnectAttempts = 8
    }
    _ = webSocketDefaults
    _ = webSocketAdvanced

    let request = SmokeGetUser()
    let login = SmokeLoginRequest(email: "user@example.com", password: "password123")
    let upload = SmokeUploadImage(imageData: Data([0x00, 0x01, 0x02]))
    _ = request
    _ = login
    _ = upload
}

_ = compileBackgroundDownloadArticleExamples
_ = compileWebSocketArticleExamples
runDocSmoke()
print("InnoNetworkDocSmoke OK")
