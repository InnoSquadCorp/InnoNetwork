#if canImport(AVFoundation) && !os(tvOS)
import AVFoundation
import Foundation

/// Owns the FairPlay content-key session attached to downloadable HLS assets.
///
/// The application-supplied delegate remains responsible for SPC/CKC
/// exchange and persistable-key storage. This object keeps that delegate
/// alive, attaches assets before media loading begins, and makes expiration
/// explicit.
@MainActor
public final class HLSFairPlaySession {
    /// The application-configured FairPlay content-key session.
    public let contentKeySession: AVContentKeySession

    // Strong ownership is intentional: AVContentKeySession does not own its
    // delegate, while the wrapper promises delegate lifetime for the session.
    // periphery:ignore
    private let retainedDelegate: any AVContentKeySessionDelegate
    private var attachedAssets: [ObjectIdentifier: AVURLAsset] = [:]
    private var isExpired = false

    /// Creates a FairPlay session with an application-owned key delegate.
    ///
    /// `storageDirectoryURL` is AVFoundation's expired-session-report
    /// directory. Persistable content keys remain application-owned and
    /// should be stored separately with the protection appropriate for the
    /// media entitlement.
    public init(
        delegate: any AVContentKeySessionDelegate,
        delegateQueue: DispatchQueue,
        storageDirectoryURL: URL? = nil
    ) throws {
        if let storageDirectoryURL {
            try Self.validateStorageDirectory(storageDirectoryURL)
            self.contentKeySession = AVContentKeySession(
                keySystem: .fairPlayStreaming,
                storageDirectoryAt: storageDirectoryURL
                    .standardizedFileURL
            )
        } else {
            self.contentKeySession = AVContentKeySession(
                keySystem: .fairPlayStreaming
            )
        }
        self.retainedDelegate = delegate
        contentKeySession.setDelegate(
            delegate,
            queue: delegateQueue
        )
    }

    /// Creates and attaches an HTTPS asset before it begins media loading.
    public func makeAsset(
        sourceURL: URL
    ) throws -> AVURLAsset {
        guard !isExpired else {
            throw HLSFairPlaySessionError.sessionExpired
        }
        do {
            try HLSAssetDownloadAdmission.validateSourceURL(sourceURL)
        } catch HLSAssetDownloadSessionError.insecureSourceURL {
            throw HLSFairPlaySessionError.insecureSourceURL
        } catch {
            throw HLSFairPlaySessionError.invalidSourceURL
        }

        let asset = AVURLAsset(url: sourceURL)
        contentKeySession.addContentKeyRecipient(asset)
        attachedAssets[ObjectIdentifier(asset)] = asset
        return asset
    }

    /// Creates and attaches a previously downloaded system-managed asset.
    ///
    /// Keep the referenced `.movpkg` at its AVFoundation-delivered location
    /// for the lifetime of playback. Validate readiness with
    /// ``HLSOfflineAssetInspector`` before presenting playback UI.
    public func makeAsset(
        storedAsset: HLSStoredAsset
    ) throws -> AVURLAsset {
        guard !isExpired else {
            throw HLSFairPlaySessionError.sessionExpired
        }

        let asset = AVURLAsset(url: storedAsset.location)
        contentKeySession.addContentKeyRecipient(asset)
        attachedAssets[ObjectIdentifier(asset)] = asset
        return asset
    }

    /// Detaches an asset after download and playback have both finished.
    public func detach(
        _ asset: AVURLAsset
    ) throws {
        guard
            attachedAssets.removeValue(
                forKey: ObjectIdentifier(asset)
            ) != nil
        else {
            throw HLSFairPlaySessionError.foreignAsset
        }
        contentKeySession.removeContentKeyRecipient(asset)
    }

    /// Normally expires the key session after every attached asset is done.
    ///
    /// Expiration is idempotent. Assets become inoperable after this call.
    public func expire() {
        guard !isExpired else {
            return
        }
        isExpired = true
        attachedAssets.removeAll(keepingCapacity: false)
        contentKeySession.expire()
    }

    private static func validateStorageDirectory(
        _ url: URL
    ) throws {
        guard
            url.isFileURL,
            url.standardizedFileURL.path != "/"
        else {
            throw HLSFairPlaySessionError.invalidStorageDirectory
        }
        let values: URLResourceValues
        do {
            values = try url.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
            )
        } catch {
            throw HLSFairPlaySessionError.invalidStorageDirectory
        }
        guard
            values.isDirectory == true,
            values.isSymbolicLink != true,
            FileManager.default.isWritableFile(
                atPath: url.path
            )
        else {
            throw HLSFairPlaySessionError.invalidStorageDirectory
        }
    }
}

/// Preflight and lifecycle failures for ``HLSFairPlaySession``.
public enum HLSFairPlaySessionError: Error, Equatable, Sendable {
    /// The protected HLS source did not use HTTPS.
    case insecureSourceURL

    /// The protected HLS source failed shared secure URL admission.
    case invalidSourceURL

    /// The expired-session-report location was not a regular local directory.
    case invalidStorageDirectory

    /// The content-key session was already expired.
    case sessionExpired

    /// The asset was not attached by this FairPlay session.
    case foreignAsset
}

extension HLSFairPlaySessionError: LocalizedError {
    /// Localized human-readable summary of the FairPlay failure.
    public var errorDescription: String? {
        switch self {
        case .insecureSourceURL:
            return fairPlayLocalized(
                "HLSFairPlaySessionError.insecureSourceURL"
            )
        case .invalidSourceURL:
            return fairPlayLocalized(
                "HLSFairPlaySessionError.invalidSourceURL"
            )
        case .invalidStorageDirectory:
            return fairPlayLocalized(
                "HLSFairPlaySessionError.invalidStorageDirectory"
            )
        case .sessionExpired:
            return fairPlayLocalized(
                "HLSFairPlaySessionError.sessionExpired"
            )
        case .foreignAsset:
            return fairPlayLocalized(
                "HLSFairPlaySessionError.foreignAsset"
            )
        }
    }

    /// Localized next step for a failed FairPlay operation.
    public var recoverySuggestion: String? {
        switch self {
        case .insecureSourceURL, .invalidSourceURL:
            return fairPlayLocalized(
                "HLSFairPlaySessionError.recovery.useHTTPSURL"
            )
        case .invalidStorageDirectory:
            return fairPlayLocalized(
                "HLSFairPlaySessionError.recovery.useRegularDirectory"
            )
        case .sessionExpired:
            return fairPlayLocalized(
                "HLSFairPlaySessionError.recovery.createSession"
            )
        case .foreignAsset:
            return fairPlayLocalized(
                "HLSFairPlaySessionError.recovery.useOwningSession"
            )
        }
    }
}

@inline(__always)
private func fairPlayLocalized(_ key: String) -> String {
    NSLocalizedString(
        key,
        bundle: .module,
        comment: "AVFoundation HLS FairPlay diagnostic"
    )
}
#endif
