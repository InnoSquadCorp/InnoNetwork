import Foundation

/// Structural failures in an application-owned local HLS playback source.
public enum HLSLocalPlaybackSourceError: Error, Equatable, Sendable {
    /// The package directory is not a bounded local file URL.
    case invalidPackageDirectoryURL

    /// The entry point is not a bounded local `.m3u8` file URL.
    case invalidEntryPlaylistURL

    /// The entry playlist is not lexically contained by the package directory.
    case entryPlaylistOutsidePackage
}

extension HLSLocalPlaybackSourceError: LocalizedError {
    /// Localized human-readable summary of the source failure.
    public var errorDescription: String? {
        switch self {
        case .invalidPackageDirectoryURL:
            return hlsLocalized(
                "HLSLocalPlaybackSourceError.invalidPackageDirectoryURL"
            )
        case .invalidEntryPlaylistURL:
            return hlsLocalized(
                "HLSLocalPlaybackSourceError.invalidEntryPlaylistURL"
            )
        case .entryPlaylistOutsidePackage:
            return hlsLocalized(
                "HLSLocalPlaybackSourceError.entryPlaylistOutsidePackage"
            )
        }
    }

    /// Localized next step for an invalid local playback source.
    public var recoverySuggestion: String? {
        hlsLocalized(
            "HLSLocalPlaybackSourceError.recovery.restorePackage"
        )
    }
}

/// A persistable, structurally validated entry point into a local HLS package.
///
/// This value does not assert that package files still exist or remain free of
/// symbolic links. A playback bridge must repeat filesystem admission when it
/// opens the source.
public struct HLSLocalPlaybackSource: Codable, Hashable, Sendable {
    private static let maximumPathUTF8ByteCount = 4_096

    /// The application-owned package directory.
    public let packageDirectoryURL: URL

    /// The package-contained multivariant or media playlist entry point.
    public let entryPlaylistURL: URL

    /// Creates a persistable local HLS playback source.
    public init(
        packageDirectoryURL: URL,
        entryPlaylistURL: URL
    ) throws {
        guard Self.isSafeFileURL(packageDirectoryURL),
            packageDirectoryURL.path != "/"
        else {
            throw HLSLocalPlaybackSourceError
                .invalidPackageDirectoryURL
        }
        guard Self.isSafeFileURL(entryPlaylistURL),
            entryPlaylistURL.pathExtension.lowercased() == "m3u8"
        else {
            throw HLSLocalPlaybackSourceError.invalidEntryPlaylistURL
        }
        let packageDirectoryURL =
            packageDirectoryURL.standardizedFileURL
        let entryPlaylistURL = entryPlaylistURL.standardizedFileURL
        guard
            Self.contains(
                entryPlaylistURL,
                in: packageDirectoryURL
            )
        else {
            throw HLSLocalPlaybackSourceError
                .entryPlaylistOutsidePackage
        }
        self.packageDirectoryURL = packageDirectoryURL
        self.entryPlaylistURL = entryPlaylistURL
    }

    /// Restores a source through the same validation as
    /// ``init(packageDirectoryURL:entryPlaylistURL:)``.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(
            keyedBy: CodingKeys.self
        )
        try self.init(
            packageDirectoryURL: container.decode(
                URL.self,
                forKey: .packageDirectoryURL
            ),
            entryPlaylistURL: container.decode(
                URL.self,
                forKey: .entryPlaylistURL
            )
        )
    }

    package init(
        validatedPackageDirectoryURL: URL,
        entryPlaylistURL: URL
    ) {
        self.packageDirectoryURL =
            validatedPackageDirectoryURL.standardizedFileURL
        self.entryPlaylistURL = entryPlaylistURL.standardizedFileURL
    }

    private static func isSafeFileURL(_ url: URL) -> Bool {
        let host = url.host(percentEncoded: false)?.lowercased()
        return url.isFileURL
            && (host == nil || host == "" || host == "localhost")
            && url.user(percentEncoded: false) == nil
            && url.password(percentEncoded: false) == nil
            && url.port == nil
            && url.query(percentEncoded: false) == nil
            && url.fragment(percentEncoded: false) == nil
            && !url.path.isEmpty
            && url.path.hasPrefix("/")
            && url.path.utf8.count <= maximumPathUTF8ByteCount
    }

    private static func contains(
        _ entryPlaylistURL: URL,
        in packageDirectoryURL: URL
    ) -> Bool {
        let directoryPath = packageDirectoryURL.path
        let prefix =
            directoryPath.hasSuffix("/")
            ? directoryPath
            : directoryPath + "/"
        return entryPlaylistURL.path.hasPrefix(prefix)
    }

    private enum CodingKeys: String, CodingKey {
        case packageDirectoryURL
        case entryPlaylistURL
    }
}
