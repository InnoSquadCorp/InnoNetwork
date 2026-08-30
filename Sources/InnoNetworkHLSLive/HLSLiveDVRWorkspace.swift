import Darwin
import Foundation

struct HLSLiveDVRWorkspace: Sendable {
    let directoryURL: URL

    static func make(
        for destinationDirectoryURL: URL
    ) throws -> HLSLiveDVRWorkspace {
        let fileManager = FileManager.default
        let parentURL = destinationDirectoryURL.deletingLastPathComponent()
        let directoryURL = parentURL.appendingPathComponent(
            ".\(destinationDirectoryURL.lastPathComponent)."
                + "\(UUID().uuidString).live-dvr-staging",
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
