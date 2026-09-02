import Foundation

/// Controls deterministic stream selection for an HLS multivariant playlist.
public enum HLSVariantSelectionPolicy: Equatable, Sendable {
    /// Selects the largest advertised resolution, then uses average and peak
    /// bandwidth to break ties.
    case highestQuality

    /// Selects the smallest advertised average or peak bandwidth.
    case lowestBandwidth

    /// Selects the highest-quality variant whose advertised dimensions do not
    /// exceed the supplied bounds.
    case maximumResolution(width: Int, height: Int)

    /// Selects the highest-quality variant whose advertised average bandwidth,
    /// or peak bandwidth when average is absent, does not exceed the limit.
    case maximumBandwidth(Int)

    /// Selects the highest-quality variant compatible with an application's
    /// declared playback limits.
    case compatible(HLSPlaybackCapabilities)
}

/// Groups playback constraints used for capability-aware variant selection.
///
/// Empty codec and video-range lists mean no constraint or preference for that
/// field. Stored values remain opaque so the pack is an immutable selection
/// command rather than a second readable configuration model.
public struct HLSPlaybackCapabilities: Equatable, Sendable {
    let maximumWidth: Int?
    let maximumHeight: Int?
    let maximumBandwidth: Int?
    let supportedCodecPrefixes: [String]
    let preferredVideoRanges: [String]

    public init(
        maximumWidth: Int? = nil,
        maximumHeight: Int? = nil,
        maximumBandwidth: Int? = nil,
        supportedCodecPrefixes: [String] = [],
        preferredVideoRanges: [String] = []
    ) {
        self.maximumWidth = maximumWidth.map { max(0, $0) }
        self.maximumHeight = maximumHeight.map { max(0, $0) }
        self.maximumBandwidth = maximumBandwidth.map { max(0, $0) }
        self.supportedCodecPrefixes =
            supportedCodecPrefixes
            .map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
            }
            .filter { !$0.isEmpty }
        self.preferredVideoRanges =
            preferredVideoRanges
            .map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
                    .uppercased()
            }
            .filter { !$0.isEmpty }
    }
}

/// Selects a deterministic preferred stream from an HLS multivariant playlist.
public struct VariantSelector: Sendable {
    /// Creates an HLS variant selector.
    public init() {}

    /// Returns the variant selected by `policy`, or `nil` when no advertised
    /// variant satisfies a constrained policy.
    public func select(
        in playlist: HLSPlaylist,
        policy: HLSVariantSelectionPolicy
    ) -> HLSVariant? {
        select(in: playlist.variants, policy: policy)
    }

    /// Returns the highest-quality advertised variant.
    ///
    /// Resolution area is compared first. Average bandwidth, then peak
    /// bandwidth, breaks ties and provides a fallback when resolution is
    /// absent.
    public func highestQuality(in playlist: HLSPlaylist) -> HLSVariant? {
        select(in: playlist, policy: .highestQuality)
    }

    func select(
        in variants: [HLSVariant],
        policy: HLSVariantSelectionPolicy
    ) -> HLSVariant? {
        switch policy {
        case .highestQuality:
            return highestQuality(in: variants)
        case .lowestBandwidth:
            return variants.filter {
                Self.preferredBandwidth($0) != nil
            }.min { lhs, rhs in
                Self.lowBandwidthKey(lhs) < Self.lowBandwidthKey(rhs)
            }
        case .maximumResolution(let width, let height):
            let normalizedWidth = max(0, width)
            let normalizedHeight = max(0, height)
            return highestQuality(
                in: variants.filter { variant in
                    guard let width = variant.width,
                        let height = variant.height,
                        width > 0,
                        height > 0
                    else {
                        return false
                    }
                    return width <= normalizedWidth
                        && height <= normalizedHeight
                }
            )
        case .maximumBandwidth(let bandwidth):
            let normalizedBandwidth = max(0, bandwidth)
            return highestQuality(
                in: variants.filter { variant in
                    guard let advertised = Self.preferredBandwidth(variant)
                    else {
                        return false
                    }
                    return advertised <= normalizedBandwidth
                }
            )
        case .compatible(let capabilities):
            return highestCompatible(
                in: variants,
                capabilities: capabilities
            )
        }
    }

    private func highestCompatible(
        in variants: [HLSVariant],
        capabilities: HLSPlaybackCapabilities
    ) -> HLSVariant? {
        variants.filter { variant in
            if let maximumWidth = capabilities.maximumWidth {
                guard let width = variant.width, width <= maximumWidth else {
                    return false
                }
            }
            if let maximumHeight = capabilities.maximumHeight {
                guard let height = variant.height, height <= maximumHeight
                else {
                    return false
                }
            }
            if let maximumBandwidth = capabilities.maximumBandwidth {
                guard let bandwidth = Self.preferredBandwidth(variant),
                    bandwidth <= maximumBandwidth
                else {
                    return false
                }
            }
            if !capabilities.supportedCodecPrefixes.isEmpty {
                let codecsAreSupported = variant.codecs.allSatisfy {
                    codec in
                    let normalizedCodec = codec.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    ).lowercased()
                    return capabilities.supportedCodecPrefixes.contains {
                        normalizedCodec.hasPrefix($0)
                    }
                }
                guard !variant.codecs.isEmpty, codecsAreSupported else {
                    return false
                }
            }
            return true
        }.max { lhs, rhs in
            Self.compatibilityKey(
                lhs,
                preferredVideoRanges:
                    capabilities.preferredVideoRanges
            )
                < Self.compatibilityKey(
                    rhs,
                    preferredVideoRanges:
                        capabilities.preferredVideoRanges
                )
        }
    }

    private func highestQuality(in variants: [HLSVariant]) -> HLSVariant? {
        variants.max { lhs, rhs in
            Self.qualityKey(lhs) < Self.qualityKey(rhs)
        }
    }

    private static func preferredBandwidth(_ variant: HLSVariant) -> Int? {
        if let averageBandwidth = variant.averageBandwidth,
            averageBandwidth > 0
        {
            return averageBandwidth
        }
        if let bandwidth = variant.bandwidth, bandwidth > 0 {
            return bandwidth
        }
        return nil
    }

    private static func lowBandwidthKey(
        _ variant: HLSVariant
    ) -> (Int, Int64, String) {
        (
            preferredBandwidth(variant) ?? Int.max,
            qualityKey(variant).0,
            variant.url.absoluteString
        )
    }

    private static func qualityKey(
        _ variant: HLSVariant
    ) -> (Int64, Int, Int, String) {
        let width = Int64(max(0, variant.width ?? 0))
        let height = Int64(max(0, variant.height ?? 0))
        let areaResult = width.multipliedReportingOverflow(by: height)
        let area = areaResult.overflow ? Int64.max : areaResult.partialValue
        return (
            area,
            variant.averageBandwidth ?? 0,
            variant.bandwidth ?? 0,
            variant.url.absoluteString
        )
    }

    private static func compatibilityKey(
        _ variant: HLSVariant,
        preferredVideoRanges: [String]
    ) -> (Int, Int64, Int, Int, String) {
        let preference: Int
        if let videoRange = variant.videoRange?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased(),
            let index = preferredVideoRanges.firstIndex(of: videoRange)
        {
            preference = preferredVideoRanges.count - index
        } else {
            preference = 0
        }
        let quality = qualityKey(variant)
        return (
            preference,
            quality.0,
            quality.1,
            quality.2,
            quality.3
        )
    }
}
