#if canImport(AVFoundation) && !os(tvOS) && !os(watchOS)
import Foundation

/// An ordered, persistable collection of system-managed HLS assets.
///
/// The library intentionally owns metadata only. AVFoundation continues to
/// own each `.movpkg` directory, while the application decides where and how
/// this Codable value is persisted.
public struct HLSAssetDownloadLibrary: Codable, Equatable, Sendable {
    private static let schemaVersion = 1
    private static let maximumAssetCount = 1_000

    /// Assets in application-defined display order.
    public let assets: [HLSStoredAsset]

    /// Creates a validated offline-asset library.
    public init(
        assets: [HLSStoredAsset] = []
    ) throws {
        guard assets.count <= Self.maximumAssetCount else {
            throw HLSAssetDownloadLibraryError.assetLimitExceeded(
                limit: Self.maximumAssetCount
            )
        }
        var identifiers = Set<String>()
        var locations = Set<URL>()
        for asset in assets {
            guard identifiers.insert(asset.id).inserted else {
                throw
                    HLSAssetDownloadLibraryError
                    .duplicateAssetIdentifier(asset.id)
            }
            guard locations.insert(asset.location).inserted else {
                throw
                    HLSAssetDownloadLibraryError
                    .duplicateAssetLocation(asset.location)
            }
        }
        self.assets = assets
    }

    /// Decodes through the same count and identity validation as
    /// ``init(assets:)``.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(
            keyedBy: CodingKeys.self
        )
        let schemaVersion = try container.decode(
            Int.self,
            forKey: .schemaVersion
        )
        guard schemaVersion == Self.schemaVersion else {
            throw
                HLSAssetDownloadLibraryError
                .unsupportedSchemaVersion(schemaVersion)
        }
        try self.init(
            assets: container.decode(
                [HLSStoredAsset].self,
                forKey: .assets
            )
        )
    }

    /// Returns the asset registered with an application identifier.
    public func asset(id: String) -> HLSStoredAsset? {
        assets.first { $0.id == id }
    }

    /// Returns a copy that contains the asset.
    ///
    /// Re-registering an identifier replaces its reference in place so the
    /// application's display order remains stable.
    public func registering(
        _ asset: HLSStoredAsset
    ) throws -> HLSAssetDownloadLibrary {
        if let index = assets.firstIndex(where: { $0.id == asset.id }) {
            var updated = assets
            updated[index] = asset
            return try HLSAssetDownloadLibrary(assets: updated)
        }
        guard assets.count < Self.maximumAssetCount else {
            throw HLSAssetDownloadLibraryError.assetLimitExceeded(
                limit: Self.maximumAssetCount
            )
        }
        return try HLSAssetDownloadLibrary(
            assets: assets + [asset]
        )
    }

    /// Returns a copy without the matching metadata reference.
    ///
    /// This does not delete the AVFoundation-owned package. Use
    /// ``HLSAssetDownloadStorage/remove(_:)`` when the bytes should also be
    /// removed.
    public func removingReference(
        id: String
    ) -> HLSAssetDownloadLibrary {
        let remaining = assets.filter { $0.id != id }
        return HLSAssetDownloadLibrary(
            validatedAssets: remaining
        )
    }

    /// Returns a copy after dropping references the system already removed.
    ///
    /// Malformed packages are surfaced as storage errors rather than silently
    /// discarded.
    public func pruningMissingAssets(
        using storage: HLSAssetDownloadStorage
    ) async throws -> HLSAssetDownloadLibrary {
        let inspection = try await storage.inspect(self)
        return try HLSAssetDownloadLibrary(
            assets: inspection.compactMap { item in
                item.availability == .available ? item.asset : nil
            }
        )
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case assets
    }

    /// Encodes a versioned metadata envelope for durable persistence.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(
            keyedBy: CodingKeys.self
        )
        try container.encode(
            Self.schemaVersion,
            forKey: .schemaVersion
        )
        try container.encode(assets, forKey: .assets)
    }

    private init(validatedAssets: [HLSStoredAsset]) {
        self.assets = validatedAssets
    }
}

/// One current availability result in an offline-asset library.
public struct HLSAssetDownloadLibraryItem: Equatable, Sendable {
    /// The persisted system-managed asset reference.
    public let asset: HLSStoredAsset

    /// Whether AVFoundation's package is still present.
    public let availability: HLSStoredAssetAvailability

    init(
        asset: HLSStoredAsset,
        availability: HLSStoredAssetAvailability
    ) {
        self.asset = asset
        self.availability = availability
    }
}

/// Validation failures for an offline-asset library.
public enum HLSAssetDownloadLibraryError: Error, Equatable, Sendable {
    /// Two entries used the same application-stable identifier.
    case duplicateAssetIdentifier(String)

    /// Two entries referenced the same system-managed package.
    case duplicateAssetLocation(URL)

    /// The bounded metadata collection exceeded its entry limit.
    case assetLimitExceeded(limit: Int)

    /// The persisted metadata uses an unknown schema.
    case unsupportedSchemaVersion(Int)
}

extension HLSAssetDownloadLibraryError: LocalizedError {
    /// Localized human-readable summary of the library failure.
    public var errorDescription: String? {
        switch self {
        case .duplicateAssetIdentifier:
            return assetLibraryLocalized(
                "HLSAssetDownloadLibraryError.duplicateAssetIdentifier"
            )
        case .duplicateAssetLocation:
            return assetLibraryLocalized(
                "HLSAssetDownloadLibraryError.duplicateAssetLocation"
            )
        case .assetLimitExceeded(let limit):
            return assetLibraryLocalizedFormat(
                "HLSAssetDownloadLibraryError.assetLimitExceeded",
                String(limit)
            )
        case .unsupportedSchemaVersion:
            return assetLibraryLocalized(
                "HLSAssetDownloadLibraryError.unsupportedSchemaVersion"
            )
        }
    }

    /// Localized next step for a failed library operation.
    public var recoverySuggestion: String? {
        switch self {
        case .duplicateAssetIdentifier, .duplicateAssetLocation:
            return assetLibraryLocalized(
                "HLSAssetDownloadLibraryError.recovery.replaceReference"
            )
        case .assetLimitExceeded:
            return assetLibraryLocalized(
                "HLSAssetDownloadLibraryError.recovery.removeReferences"
            )
        case .unsupportedSchemaVersion:
            return assetLibraryLocalized(
                "HLSAssetDownloadLibraryError.recovery.updateApplication"
            )
        }
    }
}

extension HLSAssetDownloadStorage {
    /// Inspects every library entry without changing application metadata.
    public func inspect(
        _ library: HLSAssetDownloadLibrary
    ) throws -> [HLSAssetDownloadLibraryItem] {
        try library.assets.map { asset in
            HLSAssetDownloadLibraryItem(
                asset: asset,
                availability: try availability(of: asset)
            )
        }
    }
}

@inline(__always)
private func assetLibraryLocalized(_ key: String) -> String {
    NSLocalizedString(
        key,
        bundle: .module,
        comment: "AVFoundation HLS library diagnostic"
    )
}

@inline(__always)
private func assetLibraryLocalizedFormat(
    _ key: String,
    _ arguments: CVarArg...
) -> String {
    String(
        format: assetLibraryLocalized(key),
        locale: Locale.current,
        arguments: arguments
    )
}
#endif
