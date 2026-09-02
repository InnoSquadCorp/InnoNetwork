#if canImport(AVFoundation) && !os(tvOS)
import AVFoundation
import Foundation
import os

/// An opaque application-facing identity for one FairPlay HLS asset.
///
/// Use this value to correlate content-key requests with application state
/// without retaining or exposing the asset URL.
public struct HLSFairPlayAssetID: Hashable, Sendable {
    /// The opaque UUID carried by this identity.
    public let rawValue: UUID

    /// Creates an asset identity, generating a random UUID by default.
    public init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

/// A value-only classification of an AVFoundation content-key request origin.
public enum HLSFairPlayContentKeyRequestOrigin: Equatable, Sendable {
    /// Origin inspection requires version 26 or newer.
    case unavailable

    /// AVFoundation reported no originating recipient for the request.
    ///
    /// This includes requests initiated directly by the application.
    case noRecipient

    /// An asset attached by this FairPlay session initiated the request.
    case attachedAsset(HLSFairPlayAssetID)

    /// A recipient not registered with this FairPlay session initiated it.
    case unrecognizedRecipient
}

/// Resolves content-key request origins against one FairPlay session's assets.
///
/// The resolver is safe to retain in an `AVContentKeySessionDelegate` and call
/// directly from its delegate queue. It does not retain assets or expose URLs.
public final class HLSFairPlayContentKeyRequestOriginResolver: Sendable {
    private let assetIDs = OSAllocatedUnfairLock(
        initialState: [ObjectIdentifier: HLSFairPlayAssetID]()
    )

    init() {}

    /// Classifies which registered asset initiated a content-key request.
    ///
    /// Version 26 and newer distinguish requests without a recipient, assets
    /// registered with the owning session, and other recipients. Earlier
    /// systems return ``HLSFairPlayContentKeyRequestOrigin/unavailable``.
    public func origin(
        of request: AVContentKeyRequest
    ) -> HLSFairPlayContentKeyRequestOrigin {
        guard
            #available(macOS 26,
            iOS 26,
            watchOS 26,
            visionOS 26,
            *)
        else {
            return .unavailable
        }
        return origin(of: request.originatingRecipient as AnyObject?)
    }

    func register(
        _ asset: AVURLAsset,
        id: HLSFairPlayAssetID
    ) {
        assetIDs.withLock {
            $0[ObjectIdentifier(asset)] = id
        }
    }

    func unregister(_ asset: AVURLAsset) {
        _ = assetIDs.withLock {
            $0.removeValue(forKey: ObjectIdentifier(asset))
        }
    }

    func removeAll() {
        assetIDs.withLock {
            $0.removeAll(keepingCapacity: false)
        }
    }

    func origin(
        of recipient: AnyObject?
    ) -> HLSFairPlayContentKeyRequestOrigin {
        HLSFairPlayContentKeyRequestOriginMapper.map(recipient) { identifier in
            assetIDs.withLock { $0[identifier] }
        }
    }
}

enum HLSFairPlayContentKeyRequestOriginMapper {
    static func map(
        _ recipient: AnyObject?,
        assetID: (ObjectIdentifier) -> HLSFairPlayAssetID?
    ) -> HLSFairPlayContentKeyRequestOrigin {
        guard let recipient else {
            return .noRecipient
        }
        guard let assetID = assetID(ObjectIdentifier(recipient)) else {
            return .unrecognizedRecipient
        }
        return .attachedAsset(assetID)
    }
}
#endif
