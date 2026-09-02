#if canImport(AVFoundation) && !os(tvOS)
import Foundation
import Testing

@testable import InnoNetworkHLSAVFoundation

@Suite("AVFoundation HLS asset download metrics")
struct HLSAssetDownloadMetricsTests {
    @Test("download summaries normalize unsafe scalar values")
    func normalizesUnsafeValues() {
        let date = Date(timeIntervalSince1970: 1_000)
        let variant = HLSAssetDownloadVariantSummary(
            peakBitRate: .infinity,
            averageBitRate: -1,
            hasVideo: true,
            hasAudio: false
        )
        let summary = HLSAssetDownloadSummary(
            date: date,
            recoverableErrorCount: -1,
            mediaResourceRequestCount: -1,
            bytesDownloaded: -1,
            downloadDuration: .nan,
            variants: [variant],
            hadError: true
        )

        #expect(summary.date == date)
        #expect(summary.recoverableErrorCount == 0)
        #expect(summary.mediaResourceRequestCount == 0)
        #expect(summary.bytesDownloaded == 0)
        #expect(summary.downloadDuration == nil)
        #expect(summary.variantCount == 1)
        #expect(summary.variants == [variant])
        #expect(summary.variants[0].peakBitRate == nil)
        #expect(summary.variants[0].averageBitRate == nil)
        #expect(summary.variants[0].hasVideo)
        #expect(!summary.variants[0].hasAudio)
        #expect(summary.hadError)
    }

    @Test("selected variant details remain bounded and URL-free")
    func boundsVariantDetails() {
        let variants = (0..<65).map { index in
            HLSAssetDownloadVariantSummary(
                peakBitRate: Double(index + 1),
                averageBitRate: Double(index + 1) / 2,
                hasVideo: index.isMultiple(of: 2),
                hasAudio: true
            )
        }
        let summary = HLSAssetDownloadSummary(
            date: Date(timeIntervalSince1970: 2_000),
            recoverableErrorCount: 1,
            mediaResourceRequestCount: 10,
            bytesDownloaded: 4_096,
            downloadDuration: 12.5,
            variants: Array(variants.prefix(64)),
            variantCount: variants.count,
            hadError: false
        )

        #expect(summary.recoverableErrorCount == 1)
        #expect(summary.mediaResourceRequestCount == 10)
        #expect(summary.bytesDownloaded == 4_096)
        #expect(summary.downloadDuration == 12.5)
        #expect(summary.variantCount == 65)
        #expect(summary.variants.count == 64)
        #expect(summary.didTruncateVariants)
        #expect(summary.variants.last?.peakBitRate == 64)
        #expect(!summary.hadError)

        let selection = HLSAssetDownloadVariantSelection(
            variants: Array(variants.prefix(64)),
            variantCount: variants.count
        )
        #expect(selection.variantCount == 65)
        #expect(selection.variants.count == 64)
        #expect(selection.didTruncateVariants)
        #expect(selection.variants.last?.peakBitRate == 64)
    }
}
#endif
