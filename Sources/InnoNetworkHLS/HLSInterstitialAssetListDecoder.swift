import Foundation

enum HLSInterstitialAssetListDecoder {
    static func decode(
        _ data: Data,
        maximumAssetCount: Int
    ) throws -> [HLSInterstitialAsset] {
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
        guard document.assets.count <= maximumAssetCount else {
            throw HLSExternalResourceError.tooManyInterstitialAssets(
                limit: maximumAssetCount
            )
        }
        return try document.assets.map { asset in
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
    }

    private struct Document: Decodable {
        let assets: [Asset]

        private enum CodingKeys: String, CodingKey {
            case assets = "ASSETS"
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
}
