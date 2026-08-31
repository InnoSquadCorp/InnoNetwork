#if canImport(AVFoundation) && canImport(Network)
import AVFoundation
import Foundation
import InnoNetworkHLS

/// Failures while opening an application-owned HLS package for local playback.
public enum HLSLocalPlaybackAssetError: Error, Equatable, Sendable {
    /// The package directory is missing or is not a regular directory.
    case packageUnavailable

    /// The entry playlist is missing or is not a regular file.
    case entryPlaylistUnavailable

    /// A package path or requested resource escaped filesystem admission.
    case unsafePackageContents

    /// A loopback-only HTTP endpoint could not be started.
    case loopbackServerUnavailable
}

extension HLSLocalPlaybackAssetError: LocalizedError {
    /// Localized human-readable summary of the bridge failure.
    public var errorDescription: String? {
        switch self {
        case .packageUnavailable:
            return localPlaybackLocalized(
                "HLSLocalPlaybackAssetError.packageUnavailable"
            )
        case .entryPlaylistUnavailable:
            return localPlaybackLocalized(
                "HLSLocalPlaybackAssetError.entryPlaylistUnavailable"
            )
        case .unsafePackageContents:
            return localPlaybackLocalized(
                "HLSLocalPlaybackAssetError.unsafePackageContents"
            )
        case .loopbackServerUnavailable:
            return localPlaybackLocalized(
                "HLSLocalPlaybackAssetError.loopbackServerUnavailable"
            )
        }
    }

    /// Localized next step for a failed local playback bridge.
    public var recoverySuggestion: String? {
        switch self {
        case .packageUnavailable, .entryPlaylistUnavailable,
            .unsafePackageContents:
            return localPlaybackLocalized(
                "HLSLocalPlaybackAssetError.recovery.restorePackage"
            )
        case .loopbackServerUnavailable:
            return localPlaybackLocalized(
                "HLSLocalPlaybackAssetError.recovery.retryBridge"
            )
        }
    }
}

/// Owns a loopback-only HTTP bridge and its caller-configurable `AVURLAsset`.
///
/// Keep this object alive for the complete `AVPlayerItem` lifetime. Call
/// ``close()`` after playback finishes to release the listener immediately.
/// The bridge serves only regular, package-contained files and does not expose
/// a directory listing or bind to a non-loopback interface.
@MainActor
public final class HLSLocalPlaybackAsset {
    /// The structurally validated application-owned package source.
    public let source: HLSLocalPlaybackSource

    /// The local HTTP asset to configure and pass to `AVPlayerItem`.
    public let urlAsset: AVURLAsset

    private let server: HLSLocalPlaybackHTTPServer

    /// Starts a loopback-only bridge for a raw offline or live-DVR package.
    public init(
        source: HLSLocalPlaybackSource
    ) async throws {
        let bridge = try await HLSLocalPlaybackHTTPServer.start(
            source: source
        )
        self.source = source
        self.server = bridge.server
        self.urlAsset = AVURLAsset(url: bridge.entryURL)
    }

    /// Stops accepting package requests and closes active bridge connections.
    ///
    /// Calling this method more than once has no effect. The `urlAsset` remains
    /// accessible but cannot load further resources after the bridge closes.
    public func close() {
        server.stop()
    }

    deinit {
        server.stop()
    }
}

private func localPlaybackLocalized(_ key: String) -> String {
    NSLocalizedString(
        key,
        tableName: nil,
        bundle: .module,
        value: key,
        comment: ""
    )
}
#endif
