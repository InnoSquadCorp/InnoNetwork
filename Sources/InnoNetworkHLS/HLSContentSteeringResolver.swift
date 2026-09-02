import Foundation

struct HLSPathway: Sendable {
    let id: String?
    let variants: [HLSVariant]
    let iFrameVariants: [HLSVariant]
    let renditions: [HLSRendition]
}

struct HLSPathwayCatalog: Sendable {
    let pathways: [HLSPathway]

    static func unsteered(_ playlist: HLSPlaylist) -> HLSPathwayCatalog {
        HLSPathwayCatalog(
            pathways: [
                HLSPathway(
                    id: nil,
                    variants: playlist.variants,
                    iFrameVariants: playlist.iFrameVariants,
                    renditions: playlist.renditions
                )
            ]
        )
    }
}

actor HLSContentSteeringResolver {
    private static let failedReloadDelay: Duration = .seconds(300)

    private let client: HLSHTTPClient
    private let settings: HLSContentSteeringSettings
    private let clock = ContinuousClock()
    private var entries: [URL: CacheEntry] = [:]

    init(
        client: HLSHTTPClient,
        settings: HLSContentSteeringSettings
    ) {
        self.client = client
        self.settings = settings
    }

    func catalog(
        for playlist: HLSPlaylist
    ) async throws -> HLSPathwayCatalog {
        guard let directive = playlist.contentSteering else {
            return .unsteered(playlist)
        }
        guard settings.isEnabled else {
            return Self.fallbackCatalog(
                for: playlist,
                initialPathwayID: directive.initialPathwayID
            )
        }
        let manifest = try await cachedManifest(for: directive)
        guard let manifest,
            let catalog = HLSPathwayCatalogBuilder.make(
                playlist: playlist,
                manifest: manifest
            ),
            !catalog.pathways.isEmpty
        else {
            return Self.fallbackCatalog(
                for: playlist,
                initialPathwayID: directive.initialPathwayID
            )
        }
        return catalog
    }

    private func cachedManifest(
        for directive: HLSContentSteering
    ) async throws -> HLSContentSteeringManifest? {
        let now = clock.now
        if let entry = entries[directive.serverURL] {
            if entry.isGone || now < entry.expiration {
                return entry.manifest
            }
        }

        let previous = entries[directive.serverURL]
        let requestURL = previous?.reloadURL ?? directive.serverURL
        let outcome = try await loadManifest(from: requestURL)
        switch outcome {
        case .success(let manifest):
            entries[directive.serverURL] = CacheEntry(
                manifest: manifest,
                reloadURL: manifest.reloadURL ?? requestURL,
                expiration: now.advanced(
                    by: .seconds(manifest.timeToLive)
                ),
                isGone: false
            )
            return manifest
        case .gone:
            entries[directive.serverURL] = CacheEntry(
                manifest: previous?.manifest,
                reloadURL: requestURL,
                expiration: now,
                isGone: true
            )
            return previous?.manifest
        case .unavailable(let retryDelay):
            let delay =
                retryDelay
                ?? previous?.manifest.map {
                    .seconds($0.timeToLive)
                }
                ?? Self.failedReloadDelay
            entries[directive.serverURL] = CacheEntry(
                manifest: previous?.manifest,
                reloadURL: requestURL,
                expiration: now.advanced(by: delay),
                isGone: false
            )
            return previous?.manifest
        }
    }

    private func loadManifest(
        from url: URL
    ) async throws -> ManifestLoadOutcome {
        if url.scheme?.lowercased() == "data" {
            guard
                let data = Self.decodeDataURL(
                    url,
                    maximumBytes: settings.maximumManifestBytes
                ),
                let manifest = HLSContentSteeringManifest.decode(
                    data,
                    finalURL: url
                )
            else {
                return .unavailable(retryDelay: nil)
            }
            return .success(manifest)
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue(
            "application/json, application/vnd.apple.steering-list",
            forHTTPHeaderField: "Accept"
        )
        let transfer: HLSHTTPTransfer
        do {
            transfer = try await client.transfer(
                request,
                purpose: .contentSteeringManifest,
                maximumBytes: settings.maximumManifestBytes
            )
        } catch {
            if HLSHTTPClient.isCancellation(error) {
                throw CancellationError()
            }
            return .unavailable(retryDelay: nil)
        }
        defer {
            transfer.cancel()
        }
        if let response = transfer.response as? HTTPURLResponse {
            if response.statusCode == 410 {
                return .gone
            }
            if response.statusCode == 429 {
                return .unavailable(
                    retryDelay: Self.retryDelay(from: response)
                )
            }
            guard (200..<300).contains(response.statusCode) else {
                return .unavailable(retryDelay: nil)
            }
        }
        var data = Data()
        data.reserveCapacity(
            min(
                settings.maximumManifestBytes,
                max(0, Int(transfer.response.expectedContentLength))
            )
        )
        do {
            for try await chunk in transfer.chunks {
                try Task.checkCancellation()
                data.append(chunk)
            }
        } catch {
            if HLSHTTPClient.isCancellation(error) {
                throw CancellationError()
            }
            return .unavailable(retryDelay: nil)
        }
        guard
            let manifest = HLSContentSteeringManifest.decode(
                data,
                finalURL: transfer.finalURL
            )
        else {
            return .unavailable(retryDelay: nil)
        }
        return .success(manifest)
    }

    private static func fallbackCatalog(
        for playlist: HLSPlaylist,
        initialPathwayID: String?
    ) -> HLSPathwayCatalog {
        var pathwayIDs: [String] = []
        if let initialPathwayID {
            pathwayIDs.append(initialPathwayID)
        }
        for variant in playlist.variants {
            let pathwayID = variant.pathwayID ?? HLSPathwayID.implicit
            if !pathwayIDs.contains(pathwayID) {
                pathwayIDs.append(pathwayID)
            }
        }
        let pathways: [HLSPathway] = pathwayIDs.compactMap { pathwayID in
            let variants = playlist.variants.filter {
                ($0.pathwayID ?? HLSPathwayID.implicit) == pathwayID
            }
            let iFrameVariants = playlist.iFrameVariants.filter {
                ($0.pathwayID ?? HLSPathwayID.implicit) == pathwayID
            }
            guard !variants.isEmpty else {
                return nil
            }
            return HLSPathway(
                id: pathwayID,
                variants: variants,
                iFrameVariants: iFrameVariants,
                renditions: Self.referencedRenditions(
                    variants: variants + iFrameVariants,
                    renditions: playlist.renditions
                )
            )
        }
        guard !pathways.isEmpty else {
            return .unsteered(playlist)
        }
        return HLSPathwayCatalog(pathways: pathways)
    }

    private static func referencedRenditions(
        variants: [HLSVariant],
        renditions: [HLSRendition]
    ) -> [HLSRendition] {
        let groupIDs = Set(
            variants.flatMap { variant in
                [
                    variant.audioGroupID,
                    variant.subtitleGroupID,
                    variant.videoGroupID,
                    variant.closedCaptions?.groupID,
                ].compactMap { $0 }
            }
        )
        return renditions.filter { groupIDs.contains($0.groupID) }
    }

    private static func retryDelay(
        from response: HTTPURLResponse
    ) -> Duration? {
        guard
            let value = response.value(forHTTPHeaderField: "Retry-After"),
            let seconds = Int64(value),
            seconds > 0
        else {
            return nil
        }
        return .seconds(seconds)
    }

    private static func decodeDataURL(
        _ url: URL,
        maximumBytes: Int
    ) -> Data? {
        let text = url.absoluteString
        guard text.lowercased().hasPrefix("data:"),
            let comma = text.firstIndex(of: ",")
        else {
            return nil
        }
        let metadata = text[text.index(text.startIndex, offsetBy: 5)..<comma]
        let encoded = String(text[text.index(after: comma)...])
        guard encoded.utf8.count <= maximumBytes * 4 else {
            return nil
        }
        let data: Data?
        if metadata.lowercased().split(separator: ";").contains("base64") {
            data = encoded.removingPercentEncoding.flatMap {
                Data(base64Encoded: $0)
            }
        } else {
            data = encoded.removingPercentEncoding.map {
                Data($0.utf8)
            }
        }
        guard let data, data.count <= maximumBytes else {
            return nil
        }
        return data
    }

    private struct CacheEntry: Sendable {
        let manifest: HLSContentSteeringManifest?
        let reloadURL: URL
        let expiration: ContinuousClock.Instant
        let isGone: Bool
    }

    private enum ManifestLoadOutcome: Sendable {
        case success(HLSContentSteeringManifest)
        case gone
        case unavailable(retryDelay: Duration?)
    }
}

private extension HLSClosedCaptionReference {
    var groupID: String? {
        guard case .group(let groupID) = self else {
            return nil
        }
        return groupID
    }
}

struct HLSContentSteeringManifest: Sendable {
    let timeToLive: Int64
    let reloadURL: URL?
    let pathwayPriority: [String]
    let pathwayClones: [PathwayClone]

    static func decode(
        _ data: Data,
        finalURL: URL
    ) -> HLSContentSteeringManifest? {
        guard
            let wire = try? JSONDecoder().decode(Wire.self, from: data),
            wire.version == 1,
            wire.timeToLive > 0,
            wire.timeToLive <= Int64(Int32.max),
            !wire.pathwayPriority.isEmpty,
            wire.pathwayPriority.allSatisfy(HLSPathwayID.isValid),
            Set(wire.pathwayPriority).count == wire.pathwayPriority.count,
            wire.pathwayClones?.isEmpty != true
        else {
            return nil
        }
        let reloadURL: URL?
        if let reloadURI = wire.reloadURI {
            guard !reloadURI.isEmpty else {
                return nil
            }
            if let absolute = URL(string: reloadURI),
                absolute.scheme != nil
            {
                reloadURL = absolute
            } else {
                guard
                    ["http", "https"].contains(
                        finalURL.scheme?.lowercased() ?? ""
                    ),
                    let relative = URL(
                        string: reloadURI,
                        relativeTo: finalURL
                    )?.absoluteURL
                else {
                    return nil
                }
                reloadURL = relative
            }
        } else {
            reloadURL = nil
        }
        let clones =
            wire.pathwayClones?.compactMap(
                PathwayClone.init(wire:)
            ) ?? []
        guard clones.count == (wire.pathwayClones?.count ?? 0) else {
            return nil
        }
        return HLSContentSteeringManifest(
            timeToLive: wire.timeToLive,
            reloadURL: reloadURL,
            pathwayPriority: wire.pathwayPriority,
            pathwayClones: clones
        )
    }

    struct PathwayClone: Sendable {
        let baseID: String
        let id: String
        let host: String?
        let parameters: [String: String]
        let perVariantURLs: [String: URL]
        let perRenditionURLs: [String: URL]

        fileprivate init?(wire: Wire.PathwayClone) {
            guard HLSPathwayID.isValid(wire.baseID),
                HLSPathwayID.isValid(wire.id),
                wire.baseID != wire.id
            else {
                return nil
            }
            if let host = wire.uriReplacement.host,
                !Self.isValidHost(host)
            {
                return nil
            }
            let parameters = wire.uriReplacement.parameters ?? [:]
            guard
                parameters.allSatisfy({ key, value in
                    !key.isEmpty
                        && !key.contains("\r")
                        && !key.contains("\n")
                        && !value.contains("\r")
                        && !value.contains("\n")
                })
            else {
                return nil
            }
            guard
                let variantURLs = Self.absoluteURLs(
                    wire.uriReplacement.perVariantURIs ?? [:]
                ),
                let renditionURLs = Self.absoluteURLs(
                    wire.uriReplacement.perRenditionURIs ?? [:]
                )
            else {
                return nil
            }
            self.baseID = wire.baseID
            self.id = wire.id
            self.host = wire.uriReplacement.host
            self.parameters = parameters
            self.perVariantURLs = variantURLs
            self.perRenditionURLs = renditionURLs
        }

        private static func isValidHost(_ host: String) -> Bool {
            guard !host.isEmpty,
                !host.contains("/"),
                !host.contains("@"),
                !host.contains("?")
            else {
                return false
            }
            var components = URLComponents()
            components.scheme = "https"
            components.host = host
            return components.url?.host == host && components.port == nil
        }

        private static func absoluteURLs(
            _ values: [String: String]
        ) -> [String: URL]? {
            var result: [String: URL] = [:]
            for (stableID, value) in values {
                guard !stableID.isEmpty,
                    let url = URL(string: value),
                    ["http", "https"].contains(
                        url.scheme?.lowercased() ?? ""
                    ),
                    url.host != nil
                else {
                    return nil
                }
                result[stableID] = url
            }
            return result
        }
    }

    fileprivate struct Wire: Decodable {
        let version: Int
        let timeToLive: Int64
        let reloadURI: String?
        let pathwayPriority: [String]
        let pathwayClones: [PathwayClone]?

        enum CodingKeys: String, CodingKey {
            case version = "VERSION"
            case timeToLive = "TTL"
            case reloadURI = "RELOAD-URI"
            case pathwayPriority = "PATHWAY-PRIORITY"
            case pathwayClones = "PATHWAY-CLONES"
        }

        struct PathwayClone: Decodable {
            let baseID: String
            let id: String
            let uriReplacement: URIReplacement

            enum CodingKeys: String, CodingKey {
                case baseID = "BASE-ID"
                case id = "ID"
                case uriReplacement = "URI-REPLACEMENT"
            }

            struct URIReplacement: Decodable {
                let host: String?
                let parameters: [String: String]?
                let perVariantURIs: [String: String]?
                let perRenditionURIs: [String: String]?

                enum CodingKeys: String, CodingKey {
                    case host = "HOST"
                    case parameters = "PARAMS"
                    case perVariantURIs = "PER-VARIANT-URIS"
                    case perRenditionURIs = "PER-RENDITION-URIS"
                }
            }
        }
    }
}
