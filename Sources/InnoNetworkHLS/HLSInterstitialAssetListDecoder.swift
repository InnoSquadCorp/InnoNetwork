import Foundation

package enum HLSInterstitialAssetListDecoder {
    static func decode(
        _ data: Data,
        maximumAssetCount: Int
    ) throws -> HLSInterstitialAssetListResult {
        let document: Document
        do {
            document = try JSONDecoder().decode(
                Document.self,
                from: data
            )
        } catch {
            throw HLSExternalResourceError
                .invalidInterstitialAssetList
        }
        guard !document.assets.isEmpty else {
            throw HLSExternalResourceError
                .invalidInterstitialAssetList
        }
        guard document.assets.count <= maximumAssetCount else {
            throw HLSExternalResourceError.tooManyInterstitialAssets(
                limit: maximumAssetCount
            )
        }
        let assets = try document.assets.map { asset in
            guard
                asset.duration.isFinite,
                asset.duration >= 0,
                let url = URL(string: asset.uri),
                url.scheme != nil
            else {
                throw HLSExternalResourceError
                    .invalidInterstitialAssetList
            }
            return HLSInterstitialAsset(
                url: url,
                duration: asset.duration
            )
        }
        return HLSInterstitialAssetListResult(
            assets: assets,
            skipControlOverride: document.skipControl?.value
        )
    }

    package static func decodeLocalAssetReferences(
        _ data: Data,
        maximumAssetCount: Int
    ) throws -> [String] {
        let document: Document
        do {
            document = try JSONDecoder().decode(
                Document.self,
                from: data
            )
        } catch {
            throw HLSExternalResourceError
                .invalidInterstitialAssetList
        }
        guard !document.assets.isEmpty else {
            throw HLSExternalResourceError
                .invalidInterstitialAssetList
        }
        guard document.assets.count <= maximumAssetCount else {
            throw HLSExternalResourceError.tooManyInterstitialAssets(
                limit: maximumAssetCount
            )
        }
        return try document.assets.map { asset in
            guard asset.duration.isFinite,
                asset.duration >= 0,
                !asset.uri.isEmpty,
                let components = URLComponents(string: asset.uri),
                components.scheme == nil,
                components.host == nil,
                components.user == nil,
                components.password == nil,
                components.port == nil,
                components.query == nil,
                components.fragment == nil
            else {
                throw HLSExternalResourceError
                    .invalidInterstitialAssetList
            }
            return asset.uri
        }
    }

    private struct Document: Decodable {
        let assets: [Asset]
        let skipControl: SkipControl?

        private enum CodingKeys: String, CodingKey {
            case assets = "ASSETS"
            case skipControl = "SKIP-CONTROL"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(
                keyedBy: CodingKeys.self
            )
            assets = try container.decode(
                [Asset].self,
                forKey: .assets
            )
            if container.contains(.skipControl) {
                skipControl = try container.decode(
                    SkipControl.self,
                    forKey: .skipControl
                )
            } else {
                skipControl = nil
            }
        }
    }

    private struct Asset: Decodable {
        let uri: String
        let duration: TimeInterval

        private enum CodingKeys: String, CodingKey {
            case uri = "URI"
            case duration = "DURATION"
        }
    }

    private struct SkipControl: Decodable {
        let value: HLSInterstitialSkipControl

        private enum CodingKeys: String, CodingKey {
            case offset = "OFFSET"
            case duration = "DURATION"
            case labelID = "LABEL-ID"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(
                keyedBy: CodingKeys.self
            )
            let offset = try Self.decode(
                UInt64.self,
                forKey: .offset,
                from: container
            )
            let duration = try Self.decode(
                UInt64.self,
                forKey: .duration,
                from: container
            )
            let labelID = try Self.decode(
                String.self,
                forKey: .labelID,
                from: container
            )
            guard offset != nil || duration != nil || labelID != nil,
                labelID?.allSatisfy({
                    $0.isASCII
                        && ($0.isLetter || $0 == "-" || $0 == "_")
                }) != false
            else {
                throw HLSExternalResourceError
                    .invalidInterstitialAssetList
            }
            value = HLSInterstitialSkipControl(
                offset: offset,
                duration: duration,
                labelID: labelID
            )
        }

        private static func decode<Value: Decodable>(
            _ type: Value.Type,
            forKey key: CodingKeys,
            from container: KeyedDecodingContainer<CodingKeys>
        ) throws -> Value? {
            guard container.contains(key) else {
                return nil
            }
            return try container.decode(type, forKey: key)
        }
    }
}

struct HLSInterstitialAssetListResult {
    let assets: [HLSInterstitialAsset]
    let skipControlOverride: HLSInterstitialSkipControl?
}
