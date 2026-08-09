import Foundation
import Testing

@testable import InnoNetworkHLS

@Suite("HLS resource planning")
struct HLSResourcePlanTests {
    @Test("contiguous byte ranges on one resource are coalesced")
    func coalescesContiguousRanges() throws {
        let url = try #require(
            URL(string: "https://media.example/asset.mp4")
        )
        let plan = HLSResourcePlan(
            resources: [
                .initialization(
                    url,
                    byteRange: HLSByteRange(offset: 0, length: 8)
                ),
                .segment(
                    url,
                    byteRange: HLSByteRange(offset: 8, length: 12)
                ),
                .segment(
                    url,
                    byteRange: HLSByteRange(offset: 20, length: 4)
                ),
            ],
            maximumTransferBytes: 24
        )

        #expect(
            plan.transfers == [
                HLSResourceTransfer(
                    url: url,
                    byteRange: HLSByteRange(offset: 0, length: 24)
                )
            ]
        )
    }

    @Test("gaps, URL changes, and whole resources remain separate")
    func preservesNoncontiguousResources() throws {
        let firstURL = try #require(
            URL(string: "https://media.example/first.mp4")
        )
        let secondURL = try #require(
            URL(string: "https://media.example/second.mp4")
        )
        let plan = HLSResourcePlan(
            resources: [
                .segment(
                    firstURL,
                    byteRange: HLSByteRange(offset: 0, length: 4)
                ),
                .segment(
                    firstURL,
                    byteRange: HLSByteRange(offset: 8, length: 4)
                ),
                .segment(
                    secondURL,
                    byteRange: HLSByteRange(offset: 12, length: 4)
                ),
                .segment(secondURL),
            ],
            maximumTransferBytes: 100
        )

        #expect(plan.transfers.count == 4)
    }

    @Test("coalescing never exceeds the per-transfer byte limit")
    func respectsTransferByteLimit() throws {
        let url = try #require(
            URL(string: "https://media.example/asset.mp4")
        )
        let plan = HLSResourcePlan(
            resources: [
                .segment(
                    url,
                    byteRange: HLSByteRange(offset: 0, length: 4)
                ),
                .segment(
                    url,
                    byteRange: HLSByteRange(offset: 4, length: 4)
                ),
            ],
            maximumTransferBytes: 4
        )

        #expect(plan.transfers.count == 2)
    }

    @Test("encrypted byte ranges retain their independent IV boundaries")
    func encryptedRangesAreNotCoalesced() throws {
        let resourceURL = try #require(
            URL(string: "https://media.example/asset.ts")
        )
        let keyURL = try #require(
            URL(string: "https://media.example/key.bin")
        )
        let encryption = HLSAES128Encryption(
            keyURL: keyURL,
            initializationVector: Data(repeating: 0, count: 16)
        )
        let plan = HLSResourcePlan(
            resources: [
                .segment(
                    resourceURL,
                    byteRange: HLSByteRange(offset: 0, length: 16),
                    encryption: encryption
                ),
                .segment(
                    resourceURL,
                    byteRange: HLSByteRange(offset: 16, length: 16),
                    encryption: encryption
                ),
            ],
            maximumTransferBytes: 32
        )

        #expect(plan.transfers.count == 2)
    }
}
