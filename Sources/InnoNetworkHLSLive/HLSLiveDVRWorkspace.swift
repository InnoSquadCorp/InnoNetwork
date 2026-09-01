import Darwin
import Foundation

struct HLSLiveDVRWorkspace: Sendable {
    let directoryURL: URL

    static func make(
        for destinationDirectoryURL: URL
    ) throws -> HLSLiveDVRWorkspace {
        let parentURL = destinationDirectoryURL.deletingLastPathComponent()
        return try makeTemporary(
            in: parentURL,
            name:
                ".\(destinationDirectoryURL.lastPathComponent)."
                + "\(UUID().uuidString).live-dvr-staging"
        )
    }

    static func makeTemporary(
        in parentURL: URL,
        name: String
    ) throws -> HLSLiveDVRWorkspace {
        let fileManager = FileManager.default
        let directoryURL = parentURL.appendingPathComponent(
            name,
            isDirectory: true
        )
        do {
            try fileManager.createDirectory(
                at: parentURL,
                withIntermediateDirectories: true
            )
            try fileManager.createDirectory(
                at: directoryURL.appendingPathComponent(
                    "resources",
                    isDirectory: true
                ),
                withIntermediateDirectories: true
            )
        } catch {
            throw HLSLiveDVRError.storageFailed
        }
        return HLSLiveDVRWorkspace(directoryURL: directoryURL)
    }
}

enum HLSLiveDVRFileSystem {
    static func itemExists(at url: URL) -> Bool {
        var information = stat()
        return url.withUnsafeFileSystemRepresentation { path in
            guard let path else {
                return false
            }
            return lstat(path, &information) == 0
        }
    }
}
