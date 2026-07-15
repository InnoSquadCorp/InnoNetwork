import Darwin
import Foundation

/// Validates caller-owned destination paths before a transport is created.
///
/// Destination URLs cross a filesystem trust boundary: URLSession does not
/// need them to start receiving bytes, but accepting an invalid path would
/// waste the transfer and defer a deterministic failure until completion.
/// Keep this validator internal so the public API remains centered on
/// `DownloadManager` and `DownloadError`.
enum DownloadDestinationPreflight {
    static let errorDomain = "InnoNetworkDownload.DestinationPreflight"

    static func validate(_ destinationURL: URL) throws {
        guard destinationURL.isFileURL else {
            throw failure(
                .nonFileURL,
                "Download destination must be a local file URL."
            )
        }
        guard destinationURL.query == nil, destinationURL.fragment == nil else {
            throw failure(
                .queryOrFragment,
                "Download destination must not contain a query or fragment."
            )
        }
        if let host = destinationURL.host,
            !host.isEmpty,
            host.caseInsensitiveCompare("localhost") != .orderedSame
        {
            throw failure(
                .remoteHost,
                "Download destination must not reference a remote file host."
            )
        }
        guard !destinationURL.hasDirectoryPath else {
            throw failure(
                .directoryShapedURL,
                "Download destination must identify a file, not a directory-shaped URL."
            )
        }

        let standardizedURL = destinationURL.standardizedFileURL
        guard standardizedURL.path != "/", !standardizedURL.lastPathComponent.isEmpty else {
            throw failure(
                .rootURL,
                "Download destination must not be a filesystem root."
            )
        }

        switch try nodeType(at: standardizedURL) {
        case .missing:
            break
        case .regularFile:
            break
        case .directory:
            throw failure(
                .existingDirectory,
                "An existing download destination must not be a directory."
            )
        case .symbolicLink:
            throw failure(
                .existingSymbolicLink,
                "An existing download destination must not be a symbolic link."
            )
        case .other:
            throw failure(
                .unsupportedExistingItem,
                "An existing download destination must be a regular file."
            )
        }

        try validateNearestExistingParent(
            startingAt: standardizedURL.deletingLastPathComponent()
        )
    }

    private static func validateNearestExistingParent(startingAt parentURL: URL) throws {
        var candidate = parentURL

        while true {
            // Parent symlinks are resolved for this check. The caller owns the
            // destination path, and common local roots such as `/tmp` may be
            // symlinks; the contract here is that the nearest existing parent
            // ultimately resolves to a directory. The destination item itself
            // is still inspected with `lstat` and may never be a symlink.
            switch try nodeType(at: candidate, followingSymbolicLinks: true) {
            case .directory:
                return
            case .missing:
                let next = candidate.deletingLastPathComponent()
                guard next.path != candidate.path else {
                    throw failure(
                        .missingParentDirectory,
                        "Download destination has no existing parent directory."
                    )
                }
                candidate = next
            case .symbolicLink:
                throw failure(
                    .parentNotDirectory,
                    "The nearest existing download destination parent must not be a symbolic link."
                )
            case .regularFile, .other:
                throw failure(
                    .parentNotDirectory,
                    "The nearest existing download destination parent must be a directory."
                )
            }
        }
    }

    private static func nodeType(
        at url: URL,
        followingSymbolicLinks: Bool = false
    ) throws -> NodeType {
        var status = stat()
        let result = url.withUnsafeFileSystemRepresentation { representation -> Int32 in
            guard let representation else { return -1 }
            if followingSymbolicLinks {
                return stat(representation, &status)
            }
            return lstat(representation, &status)
        }
        if result == 0 {
            switch status.st_mode & S_IFMT {
            case S_IFREG:
                return .regularFile
            case S_IFDIR:
                return .directory
            case S_IFLNK:
                return .symbolicLink
            default:
                return .other
            }
        }

        let code = errno
        if code == ENOENT || code == ENOTDIR {
            return .missing
        }
        throw failure(
            .metadataUnavailable,
            "Download destination metadata could not be inspected: \(String(cString: strerror(code)))."
        )
    }

    private static func failure(
        _ code: DownloadDestinationPreflightFailure.Code,
        _ message: String
    ) -> DownloadDestinationPreflightFailure {
        DownloadDestinationPreflightFailure(code: code, message: message)
    }

    private enum NodeType {
        case missing
        case regularFile
        case directory
        case symbolicLink
        case other
    }
}

struct DownloadDestinationPreflightFailure: Error, Sendable, CustomNSError, LocalizedError {
    enum Code: Int, Sendable {
        case nonFileURL = 1
        case queryOrFragment
        case remoteHost
        case directoryShapedURL
        case rootURL
        case existingDirectory
        case existingSymbolicLink
        case unsupportedExistingItem
        case missingParentDirectory
        case parentNotDirectory
        case metadataUnavailable
    }

    static let errorDomain = DownloadDestinationPreflight.errorDomain

    let code: Code
    let message: String

    var errorCode: Int { code.rawValue }
    var errorDescription: String? { message }
    var errorUserInfo: [String: Any] {
        [NSLocalizedDescriptionKey: message]
    }
}
