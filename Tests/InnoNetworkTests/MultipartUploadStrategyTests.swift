import Foundation
import Testing

@testable import InnoNetwork

@Suite("MultipartUploadStrategy threshold helpers")
struct MultipartUploadStrategyThresholdTests {
    @Test("platformDefault picks the documented threshold for the host platform")
    func platformDefaultPicksDocumentedThreshold() async {
        guard case .streamingThreshold(let bytes) = MultipartUploadStrategy.platformDefault else {
            Issue.record("platformDefault must resolve to streamingThreshold")
            return
        }
        #if os(iOS) || os(watchOS) || os(tvOS)
        #expect(bytes == 16 * 1024 * 1024)
        #elseif os(macOS) || os(visionOS)
        #expect(bytes == 50 * 1024 * 1024)
        #else
        #expect(bytes == 16 * 1024 * 1024)
        #endif
    }

    @Test("threshold(bytes:) clamps zero and negative values to 1 byte")
    func thresholdClampsBelowZero() async {
        if case .streamingThreshold(let zero) = MultipartUploadStrategy.threshold(bytes: 0) {
            #expect(zero == 1)
        } else {
            Issue.record(".threshold(bytes:) must produce streamingThreshold")
        }
        if case .streamingThreshold(let negative) = MultipartUploadStrategy.threshold(bytes: -42) {
            #expect(negative == 1)
        } else {
            Issue.record(".threshold(bytes:) must produce streamingThreshold")
        }
    }

    @Test("threshold(bytes:) preserves positive byte counts")
    func thresholdPreservesPositiveValues() async {
        if case .streamingThreshold(let value) = MultipartUploadStrategy.threshold(bytes: 1_234_567) {
            #expect(value == 1_234_567)
        } else {
            Issue.record(".threshold(bytes:) must produce streamingThreshold")
        }
    }
}
