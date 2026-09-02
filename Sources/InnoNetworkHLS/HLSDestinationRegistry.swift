import Darwin
import Foundation

actor HLSInProcessDestinationRegistry {
    static let shared = HLSInProcessDestinationRegistry()

    private var activeDestinations: Set<URL> = []

    func claim(_ destinationURL: URL) -> Bool {
        activeDestinations.insert(destinationURL).inserted
    }

    func release(_ destinationURL: URL) {
        activeDestinations.remove(destinationURL)
    }
}

package struct HLSDestinationLease: Sendable {
    private let destinationKey: URL
    private let crossProcessLease: HLSCrossProcessDestinationLease

    package static func acquire(
        for destinationURL: URL
    ) async throws -> Self {
        let destinationKey = HLSDestinationIdentity.canonicalURL(
            for: destinationURL
        )
        guard
            await HLSInProcessDestinationRegistry.shared.claim(
                destinationKey
            )
        else {
            throw HLSDownloadError.destinationInUse
        }

        do {
            guard
                let crossProcessLease =
                    try HLSCrossProcessDestinationLock.acquire(
                        destinationURL: destinationKey
                    )
            else {
                throw HLSDownloadError.destinationInUse
            }
            return Self(
                destinationKey: destinationKey,
                crossProcessLease: crossProcessLease
            )
        } catch {
            await HLSInProcessDestinationRegistry.shared.release(
                destinationKey
            )
            throw error
        }
    }

    package func release() async {
        await crossProcessLease.release()
        await HLSInProcessDestinationRegistry.shared.release(
            destinationKey
        )
    }
}

enum HLSDestinationIdentity {
    static func canonicalURL(for destinationURL: URL) -> URL {
        let canonicalParent =
            destinationURL
            .deletingLastPathComponent()
            .standardizedFileURL
            .resolvingSymlinksInPath()
        return
            canonicalParent
            .appendingPathComponent(destinationURL.lastPathComponent)
            .standardizedFileURL
    }
}

enum HLSCrossProcessDestinationLock {
    static func acquire(
        destinationURL: URL
    ) throws -> HLSCrossProcessDestinationLease? {
        let parentURL = destinationURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: parentURL,
            withIntermediateDirectories: true
        )

        let lockDirectoryURL = parentURL.appendingPathComponent(
            ".innonetwork-hls-locks",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: lockDirectoryURL,
            withIntermediateDirectories: true
        )
        excludeFromBackup(lockDirectoryURL)

        let lockURL = lockDirectoryURL.appendingPathComponent(
            "\(lockIdentity(for: destinationURL)).lock"
        )
        let descriptor = try openLockFile(at: lockURL)
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let errorCode = errno
            close(descriptor)
            if errorCode == EWOULDBLOCK || errorCode == EAGAIN {
                return nil
            }
            throw posixError(errorCode)
        }
        return HLSCrossProcessDestinationLease(
            descriptor: descriptor
        )
    }

    private static func lockIdentity(
        for destinationURL: URL
    ) -> String {
        let parentURL = destinationURL.deletingLastPathComponent()
        let supportsCaseSensitiveNames =
            try? parentURL.resourceValues(
                forKeys: [.volumeSupportsCaseSensitiveNamesKey]
            ).volumeSupportsCaseSensitiveNames
        var identity = destinationURL.path
        if supportsCaseSensitiveNames != true {
            identity = identity.folding(
                options: [
                    .caseInsensitive,
                    .diacriticInsensitive,
                    .widthInsensitive,
                ],
                locale: Locale(identifier: "en_US_POSIX")
            )
        }
        return HLSContentFingerprint.sha256(identity)
    }

    private static func openLockFile(at url: URL) throws -> Int32 {
        let descriptor = url.withUnsafeFileSystemRepresentation {
            path -> Int32 in
            guard let path else {
                return -1
            }
            return Darwin.open(
                path,
                O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW,
                S_IRUSR | S_IWUSR
            )
        }
        guard descriptor >= 0 else {
            throw posixError()
        }
        guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
            let errorCode = errno
            close(descriptor)
            throw posixError(errorCode)
        }
        return descriptor
    }

    private static func excludeFromBackup(_ directoryURL: URL) {
        var directoryURL = directoryURL
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? directoryURL.setResourceValues(values)
    }

    private static func posixError(
        _ errorCode: Int32 = errno
    ) -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errorCode) ?? .EIO)
    }
}

actor HLSCrossProcessDestinationLease {
    private var descriptor: Int32?

    init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    deinit {
        if let descriptor {
            flock(descriptor, LOCK_UN)
            close(descriptor)
        }
    }

    func release() {
        guard let descriptor else {
            return
        }
        flock(descriptor, LOCK_UN)
        close(descriptor)
        self.descriptor = nil
    }
}
