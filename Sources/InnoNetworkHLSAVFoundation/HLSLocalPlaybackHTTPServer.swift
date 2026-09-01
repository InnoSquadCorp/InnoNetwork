#if canImport(AVFoundation) && canImport(Network)
import Foundation
import InnoNetworkHLS
import Network
import os

final class HLSLocalPlaybackHTTPServer: Sendable {
    private static let maximumConnectionCount = 32
    private static let startupTimeout: Duration = .seconds(5)

    private struct State {
        var didStop = false
        var connections: [ObjectIdentifier: HLSLocalPlaybackHTTPConnection] = [:]
    }

    private let listener: NWListener
    private let queue = DispatchQueue(
        label: "com.innosquad.InnoNetwork.HLSLocalPlayback"
    )
    private let root: HLSLocalPlaybackPackageRoot
    private let token: String
    private let readiness: AsyncStream<Result<UInt16, HLSLocalPlaybackAssetError>>
    private let readinessContinuation: AsyncStream<Result<UInt16, HLSLocalPlaybackAssetError>>.Continuation
    private let state = OSAllocatedUnfairLock(
        initialState: State()
    )

    private init(
        listener: NWListener,
        root: HLSLocalPlaybackPackageRoot,
        token: String
    ) {
        self.listener = listener
        self.root = root
        self.token = token
        let readiness = AsyncStream<
            Result<UInt16, HLSLocalPlaybackAssetError>
        >.makeStream(bufferingPolicy: .bufferingNewest(1))
        self.readiness = readiness.stream
        self.readinessContinuation = readiness.continuation
    }

    static func start(
        source: HLSLocalPlaybackSource
    ) async throws -> (
        server: HLSLocalPlaybackHTTPServer,
        entryURL: URL
    ) {
        let root = try HLSLocalPlaybackPackageRoot(source: source)
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(
            host: "127.0.0.1",
            port: .any
        )
        parameters.acceptLocalOnly = true
        parameters.allowLocalEndpointReuse = false
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            throw HLSLocalPlaybackAssetError
                .loopbackServerUnavailable
        }
        listener.newConnectionLimit = maximumConnectionCount
        let server = HLSLocalPlaybackHTTPServer(
            listener: listener,
            root: root,
            token: UUID().uuidString.lowercased()
        )
        server.configureListener()
        listener.start(queue: server.queue)

        let port: UInt16
        do {
            port = try await withTaskCancellationHandler {
                try await server.waitUntilReady()
            } onCancel: {
                server.stop()
            }
        } catch {
            server.stop()
            throw error
        }
        guard
            let entryURL = root.entryURL(
                port: port,
                token: server.token
            )
        else {
            server.stop()
            throw HLSLocalPlaybackAssetError
                .loopbackServerUnavailable
        }
        return (server, entryURL)
    }

    func stop() {
        let connections = state.withLock { state -> [HLSLocalPlaybackHTTPConnection] in
            guard !state.didStop else {
                return []
            }
            state.didStop = true
            let connections = Array(state.connections.values)
            state.connections.removeAll(keepingCapacity: false)
            return connections
        }
        readinessContinuation.finish()
        listener.cancel()
        connections.forEach { $0.cancel() }
    }

    private func configureListener() {
        listener.stateUpdateHandler = { [weak self] listenerState in
            self?.receive(listenerState)
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
    }

    private func receive(_ listenerState: NWListener.State) {
        switch listenerState {
        case .ready:
            guard let port = listener.port?.rawValue else {
                readinessContinuation.yield(
                    .failure(.loopbackServerUnavailable)
                )
                readinessContinuation.finish()
                return
            }
            readinessContinuation.yield(.success(port))
            readinessContinuation.finish()
        case .failed:
            readinessContinuation.yield(
                .failure(.loopbackServerUnavailable)
            )
            readinessContinuation.finish()
        case .cancelled:
            readinessContinuation.finish()
        case .setup, .waiting:
            break
        @unknown default:
            readinessContinuation.yield(
                .failure(.loopbackServerUnavailable)
            )
            readinessContinuation.finish()
        }
    }

    private func waitUntilReady() async throws -> UInt16 {
        try await withThrowingTaskGroup(of: UInt16.self) { group in
            group.addTask { [readiness] in
                var iterator = readiness.makeAsyncIterator()
                guard let result = await iterator.next() else {
                    if Task.isCancelled {
                        throw CancellationError()
                    }
                    throw HLSLocalPlaybackAssetError
                        .loopbackServerUnavailable
                }
                return try result.get()
            }
            group.addTask {
                try await Task.sleep(for: Self.startupTimeout)
                throw HLSLocalPlaybackAssetError
                    .loopbackServerUnavailable
            }
            guard let port = try await group.next() else {
                throw HLSLocalPlaybackAssetError
                    .loopbackServerUnavailable
            }
            group.cancelAll()
            return port
        }
    }

    private func accept(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        let admitted = state.withLock { state in
            guard
                !state.didStop,
                state.connections.count
                    < Self.maximumConnectionCount
            else {
                return false
            }
            let handler = HLSLocalPlaybackHTTPConnection(
                connection: connection,
                queue: queue,
                root: root,
                token: token,
                onFinish: { [weak self] in
                    self?.removeConnection(id: id)
                }
            )
            state.connections[id] = handler
            return true
        }
        guard admitted else {
            connection.cancel()
            return
        }
        state.withLock { $0.connections[id] }?.start()
    }

    private func removeConnection(id: ObjectIdentifier) {
        _ = state.withLock { state in
            state.connections.removeValue(forKey: id)
        }
    }
}

struct HLSLocalPlaybackPackageRoot: Sendable {
    private static let maximumRequestPathUTF8ByteCount = 4_096

    let directoryURL: URL
    let entryRelativePath: String
    let frozenResourceDataByRelativePath: [String: Data]

    init(source: HLSLocalPlaybackSource) throws {
        let snapshot: HLSLocalPlaybackPackageSnapshot
        do {
            snapshot = try HLSLocalPlaybackPackageSnapshot(
                source: source
            )
        } catch let error as HLSLocalPlaybackPackageValidationError {
            switch error {
            case .packageUnavailable:
                throw HLSLocalPlaybackAssetError.packageUnavailable
            case .entryPlaylistUnavailable:
                throw HLSLocalPlaybackAssetError
                    .entryPlaylistUnavailable
            case .unsafePackageContents:
                throw HLSLocalPlaybackAssetError.unsafePackageContents
            }
        } catch {
            throw HLSLocalPlaybackAssetError.unsafePackageContents
        }
        self.directoryURL = snapshot.directoryURL
        self.entryRelativePath = snapshot.entryRelativePath
        self.frozenResourceDataByRelativePath =
            snapshot.frozenResourceDataByRelativePath
    }

    func entryURL(port: UInt16, token: String) -> URL? {
        guard
            var base = URL(
                string: "http://127.0.0.1:\(port)/"
            )
        else {
            return nil
        }
        base.appendPathComponent(token, isDirectory: true)
        base.appendPathComponent(entryRelativePath)
        return base
    }

    func resource(
        requestTarget: String,
        token: String
    ) throws -> HLSLocalPlaybackFile {
        guard
            requestTarget.utf8.count
                <= Self.maximumRequestPathUTF8ByteCount,
            let components = URLComponents(
                string: "http://localhost\(requestTarget)"
            ),
            components.query == nil,
            components.fragment == nil
        else {
            throw HLSLocalPlaybackHTTPError.badRequest
        }
        let encodedComponents = components.percentEncodedPath
            .split(separator: "/", omittingEmptySubsequences: true)
        guard encodedComponents.first.map(String.init) == token else {
            throw HLSLocalPlaybackHTTPError.forbidden
        }
        let pathComponents = try encodedComponents.dropFirst().map {
            encoded -> String in
            guard
                let decoded = String(encoded).removingPercentEncoding,
                !decoded.isEmpty,
                decoded != ".",
                decoded != "..",
                !decoded.contains("/"),
                !decoded.contains("\\"),
                !decoded.unicodeScalars.contains(where: {
                    CharacterSet.controlCharacters.contains($0)
                })
            else {
                throw HLSLocalPlaybackHTTPError.forbidden
            }
            return decoded
        }
        guard !pathComponents.isEmpty else {
            throw HLSLocalPlaybackHTTPError.notFound
        }
        var resourceURL = directoryURL
        for component in pathComponents {
            resourceURL.appendPathComponent(component)
        }
        resourceURL = resourceURL.standardizedFileURL
        let resolvedURL =
            resourceURL
            .resolvingSymlinksInPath()
            .standardizedFileURL
        guard resourceURL.path == resolvedURL.path,
            Self.contains(resolvedURL, in: directoryURL)
        else {
            throw HLSLocalPlaybackHTTPError.forbidden
        }
        let relativePath = String(
            resolvedURL.path.dropFirst(
                Self.directoryPrefix(directoryURL.path).count
            )
        )
        if let data = frozenResourceDataByRelativePath[relativePath] {
            return HLSLocalPlaybackFile(
                storage: .data(data),
                size: Int64(data.count),
                contentType: Self.contentType(
                    for: resourceURL.pathExtension
                )
            )
        }
        let values: URLResourceValues
        do {
            values = try resourceURL.resourceValues(
                forKeys: [
                    .fileSizeKey,
                    .isRegularFileKey,
                    .isSymbolicLinkKey,
                ]
            )
        } catch {
            throw HLSLocalPlaybackHTTPError.notFound
        }
        guard values.isRegularFile == true,
            values.isSymbolicLink != true,
            let fileSize = values.fileSize,
            fileSize >= 0
        else {
            throw HLSLocalPlaybackHTTPError.forbidden
        }
        return HLSLocalPlaybackFile(
            storage: .file(resourceURL),
            size: Int64(fileSize),
            contentType: Self.contentType(
                for: resourceURL.pathExtension
            )
        )
    }

    private static func contentType(
        for pathExtension: String
    ) -> String {
        switch pathExtension.lowercased() {
        case "m3u8", "m3u":
            return "application/vnd.apple.mpegurl"
        case "ts":
            return "video/mp2t"
        case "mp4":
            return "video/mp4"
        case "m4s":
            return "video/iso.segment"
        case "m4a":
            return "audio/mp4"
        case "aac":
            return "audio/aac"
        case "vtt", "webvtt":
            return "text/vtt"
        case "json":
            return "application/json"
        default:
            return "application/octet-stream"
        }
    }

    private static func contains(
        _ resourceURL: URL,
        in directoryURL: URL
    ) -> Bool {
        resourceURL.path.hasPrefix(
            directoryPrefix(directoryURL.path)
        )
    }

    private static func directoryPrefix(_ path: String) -> String {
        path.hasSuffix("/") ? path : path + "/"
    }
}

struct HLSLocalPlaybackFile: Sendable {
    enum Storage: Sendable {
        case data(Data)
        case file(URL)
    }

    let storage: Storage
    let size: Int64
    let contentType: String
}
#endif
