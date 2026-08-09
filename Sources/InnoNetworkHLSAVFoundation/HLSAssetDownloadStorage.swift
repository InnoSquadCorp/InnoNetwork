#if canImport(AVFoundation) && !os(tvOS) && !os(watchOS)
import AVFoundation
import Foundation
import InnoNetwork

/// A persistable reference to one system-managed offline HLS asset.
///
/// Persist this value rather than moving the `.movpkg` directory. The URL
/// remains owned by AVFoundation and can be checked again after relaunch.
public struct HLSStoredAsset: Codable, Hashable, Sendable {
    /// The application-stable download identifier.
    public let id: String

    /// The system-managed `.movpkg` location.
    public let location: URL

    /// Creates a restorable system-managed asset reference.
    public init(
        id: String,
        location: URL
    ) throws {
        guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw HLSAssetDownloadStorageError.invalidAssetIdentifier
        }
        guard
            location.isFileURL,
            location.pathExtension.lowercased() == "movpkg",
            location.standardizedFileURL.path != "/"
        else {
            throw HLSAssetDownloadStorageError.invalidAssetURL
        }
        self.id = id
        self.location = location.standardizedFileURL
    }

    /// Restores a stored reference through the same validation as
    /// ``init(id:location:)``.
    public init(
        from decoder: any Decoder
    ) throws {
        let container = try decoder.container(
            keyedBy: CodingKeys.self
        )
        try self.init(
            id: container.decode(String.self, forKey: .id),
            location: container.decode(URL.self, forKey: .location)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case location
    }
}

/// Whether a persisted system-managed asset still exists on disk.
public enum HLSStoredAssetAvailability: Equatable, Sendable {
    /// The `.movpkg` directory is present.
    case available

    /// The system or application has removed the asset.
    case missing
}

/// Relative eviction importance for a system-managed offline asset.
public enum HLSAssetDownloadEvictionPriority: Equatable, Sendable {
    /// Allows the system to purge this asset before important assets.
    case standard

    /// Requests that the system purge this asset after standard assets.
    case important
}

/// Best-effort automatic-purge policy for one offline HLS asset.
public struct HLSAssetDownloadStoragePolicy: Equatable, Sendable {
    /// The date after which the system may prioritize the asset for eviction.
    public let expirationDate: Date

    /// The asset's relative eviction importance.
    public let evictionPriority: HLSAssetDownloadEvictionPriority

    /// Creates an automatic-purge policy.
    public init(
        expirationDate: Date,
        evictionPriority: HLSAssetDownloadEvictionPriority = .standard
    ) {
        self.expirationDate = expirationDate
        self.evictionPriority = evictionPriority
    }
}

/// Failures produced by system-managed offline-asset storage operations.
public enum HLSAssetDownloadStorageError: Error, Equatable, Sendable {
    /// The stored application identifier was empty.
    case invalidAssetIdentifier

    /// The location was not a local `.movpkg` URL.
    case invalidAssetURL

    /// A file exists at the location but is not a regular package directory.
    case invalidAssetPackage

    /// The system-managed package is no longer present.
    case assetNotFound

    /// The host process cannot use AVFoundation's storage-policy manager.
    case storagePolicyUnavailable

    /// The package could not be removed.
    case removalFailed(SendableUnderlyingError)
}

extension HLSAssetDownloadStorageError: LocalizedError {
    /// Localized human-readable summary of the storage failure.
    public var errorDescription: String? {
        switch self {
        case .invalidAssetIdentifier:
            return assetStorageLocalized(
                "HLSAssetDownloadStorageError.invalidAssetIdentifier"
            )
        case .invalidAssetURL:
            return assetStorageLocalized(
                "HLSAssetDownloadStorageError.invalidAssetURL"
            )
        case .invalidAssetPackage:
            return assetStorageLocalized(
                "HLSAssetDownloadStorageError.invalidAssetPackage"
            )
        case .assetNotFound:
            return assetStorageLocalized(
                "HLSAssetDownloadStorageError.assetNotFound"
            )
        case .storagePolicyUnavailable:
            return assetStorageLocalized(
                "HLSAssetDownloadStorageError.storagePolicyUnavailable"
            )
        case .removalFailed:
            return assetStorageLocalized(
                "HLSAssetDownloadStorageError.removalFailed"
            )
        }
    }

    /// Localized next step for a failed storage operation.
    public var recoverySuggestion: String? {
        switch self {
        case .invalidAssetIdentifier, .invalidAssetURL:
            return assetStorageLocalized(
                "HLSAssetDownloadStorageError.recovery.restoreReference"
            )
        case .invalidAssetPackage:
            return assetStorageLocalized(
                "HLSAssetDownloadStorageError.recovery.discardReference"
            )
        case .assetNotFound:
            return assetStorageLocalized(
                "HLSAssetDownloadStorageError.recovery.discardReference"
            )
        case .storagePolicyUnavailable:
            return assetStorageLocalized(
                "HLSAssetDownloadStorageError.recovery.useApplicationHost"
            )
        case .removalFailed:
            return assetStorageLocalized(
                "HLSAssetDownloadStorageError.recovery.retryRemoval"
            )
        }
    }
}

/// Manages availability, eviction policy, and removal for AVFoundation assets.
///
/// This actor serializes filesystem mutations with storage-policy updates.
/// Removing an already missing asset succeeds and returns `false`.
public actor HLSAssetDownloadStorage {
    private let fileManager: FileManager
    private let storageManager: AVAssetDownloadStorageManager

    /// Creates a storage lifecycle manager.
    public init() {
        self.fileManager = .default
        self.storageManager = .shared()
    }

    /// Returns whether the referenced package is still available.
    public func availability(
        of asset: HLSStoredAsset
    ) throws -> HLSStoredAssetAvailability {
        guard fileManager.fileExists(atPath: asset.location.path) else {
            return .missing
        }
        try validatePackage(at: asset.location)
        return .available
    }

    /// Returns the current automatic-purge policy, when one was set.
    public func policy(
        for asset: HLSStoredAsset
    ) throws -> HLSAssetDownloadStoragePolicy? {
        guard try availability(of: asset) == .available else {
            return nil
        }
        try validateStoragePolicyEnvironment()
        guard
            let policy = storageManager.storageManagementPolicy(
                for: asset.location
            )
        else {
            return nil
        }
        return HLSAssetDownloadStoragePolicy(
            expirationDate: policy.expirationDate,
            evictionPriority:
                policy.priority == .important
                ? .important
                : .standard
        )
    }

    /// Applies a best-effort automatic-purge policy.
    public func setPolicy(
        _ policy: HLSAssetDownloadStoragePolicy,
        for asset: HLSStoredAsset
    ) throws {
        guard try availability(of: asset) == .available else {
            throw HLSAssetDownloadStorageError.assetNotFound
        }
        try validateStoragePolicyEnvironment()
        let systemPolicy =
            AVMutableAssetDownloadStorageManagementPolicy()
        systemPolicy.expirationDate = policy.expirationDate
        systemPolicy.priority =
            policy.evictionPriority == .important
            ? .important
            : .default
        storageManager.setStorageManagementPolicy(
            systemPolicy,
            for: asset.location
        )
    }

    /// Removes the system-managed package.
    ///
    /// - Returns: `true` when a package was removed, or `false` when it was
    ///   already missing.
    @discardableResult
    public func remove(
        _ asset: HLSStoredAsset
    ) throws -> Bool {
        guard fileManager.fileExists(atPath: asset.location.path) else {
            return false
        }
        try validatePackage(at: asset.location)
        do {
            try fileManager.removeItem(at: asset.location)
            return true
        } catch {
            throw HLSAssetDownloadStorageError.removalFailed(
                SendableUnderlyingError(error)
            )
        }
    }

    private func validatePackage(
        at location: URL
    ) throws {
        let values: URLResourceValues
        do {
            values = try location.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
            )
        } catch {
            throw HLSAssetDownloadStorageError.invalidAssetPackage
        }
        guard
            values.isDirectory == true,
            values.isSymbolicLink != true
        else {
            throw HLSAssetDownloadStorageError.invalidAssetPackage
        }
    }

    private func validateStoragePolicyEnvironment() throws {
        guard Bundle.main.bundleIdentifier != nil else {
            throw HLSAssetDownloadStorageError
                .storagePolicyUnavailable
        }
    }
}

extension HLSAssetDownload {
    /// Binds a delivered system location to this download's stable identifier.
    public func storedAsset(
        at location: URL
    ) throws -> HLSStoredAsset {
        try HLSStoredAsset(id: id, location: location)
    }
}

@inline(__always)
private func assetStorageLocalized(_ key: String) -> String {
    NSLocalizedString(
        key,
        bundle: .module,
        comment: "AVFoundation HLS storage diagnostic"
    )
}
#endif
