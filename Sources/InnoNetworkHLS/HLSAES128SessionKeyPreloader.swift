import Foundation
import InnoNetwork

struct HLSAES128SessionKeyPreload: Sendable {
    static let empty = HLSAES128SessionKeyPreload(tasksByURL: [:])

    private let tasksByURL: [URL: Task<Data?, Never>]

    init(tasksByURL: [URL: Task<Data?, Never>]) {
        self.tasksByURL = tasksByURL
    }

    func resolve(
        requiredKeyURLs: Set<URL>
    ) async throws -> HLSAES128KeySet {
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            for (url, task) in tasksByURL
            where !requiredKeyURLs.contains(url) {
                task.cancel()
            }

            var keysByURL: [URL: Data] = [:]
            for keyURL in requiredKeyURLs {
                try Task.checkCancellation()
                if let task = tasksByURL[keyURL] {
                    let key = await task.value
                    try Task.checkCancellation()
                    guard let key else {
                        continue
                    }
                    keysByURL[keyURL] = key
                }
            }
            return HLSAES128KeySet(keysByURL: keysByURL)
        } onCancel: {
            cancel()
        }
    }

    func cancel() {
        for task in tasksByURL.values {
            task.cancel()
        }
    }
}

struct HLSAES128SessionKeyPreloader: Sendable {
    private static let maximumKeyCount = 4

    private let policy: HLSSessionKeyPreloadPolicy
    private let fetcher: HLSAES128KeyFetcher

    init(
        client: HLSHTTPClient,
        policy: HLSSessionKeyPreloadPolicy,
        clock: any InnoNetworkClock,
        networkMonitor: (any NetworkMonitoring)? = NetworkMonitor.shared
    ) {
        self.policy = policy
        self.fetcher = HLSAES128KeyFetcher(
            client: client,
            retryPolicy: nil,
            clock: clock,
            networkMonitor: networkMonitor
        )
    }

    func start(
        sessionKeys: [HLSSessionKey],
        isDownloadExecution: Bool
    ) -> HLSAES128SessionKeyPreload {
        guard
            !Task.isCancelled,
            isDownloadExecution,
            policy == .identityAES128
        else {
            return .empty
        }

        var tasksByURL: [URL: Task<Data?, Never>] = [:]
        for sessionKey in sessionKeys
        where sessionKey.method == "AES-128"
            && sessionKey.isIdentityFormat
            && sessionKey.keyFormatVersions == [1]
            && tasksByURL[sessionKey.url] == nil
        {
            let keyURL = sessionKey.url
            tasksByURL[keyURL] = Task {
                do {
                    try Task.checkCancellation()
                    return try await fetcher.fetch(keyURL)
                } catch {
                    return nil
                }
            }
            if tasksByURL.count == Self.maximumKeyCount {
                break
            }
        }
        return HLSAES128SessionKeyPreload(tasksByURL: tasksByURL)
    }
}
