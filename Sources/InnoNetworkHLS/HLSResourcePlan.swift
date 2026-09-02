import Foundation

struct HLSResourceTransfer: Equatable, Sendable {
    let url: URL
    let byteRange: HLSByteRange?
    let encryption: HLSAES128Encryption?

    init(
        url: URL,
        byteRange: HLSByteRange?,
        encryption: HLSAES128Encryption? = nil
    ) {
        self.url = url
        self.byteRange = byteRange
        self.encryption = encryption
    }
}

struct HLSResourcePlan: Equatable, Sendable {
    let transfers: [HLSResourceTransfer]

    init(
        resources: [HLSMediaResource],
        maximumTransferBytes: Int
    ) {
        var transfers: [HLSResourceTransfer] = []
        transfers.reserveCapacity(resources.count)

        for resource in resources {
            let transfer = HLSResourceTransfer(
                url: resource.url,
                byteRange: resource.byteRange,
                encryption: resource.encryption
            )
            guard
                let previous = transfers.last,
                let coalesced = Self.coalesce(
                    previous,
                    transfer,
                    maximumTransferBytes: maximumTransferBytes
                )
            else {
                transfers.append(transfer)
                continue
            }
            transfers[transfers.index(before: transfers.endIndex)] =
                coalesced
        }
        self.transfers = transfers
    }

    private static func coalesce(
        _ previous: HLSResourceTransfer,
        _ current: HLSResourceTransfer,
        maximumTransferBytes: Int
    ) -> HLSResourceTransfer? {
        guard previous.encryption == nil,
            current.encryption == nil,
            previous.url == current.url,
            let previousRange = previous.byteRange,
            let currentRange = current.byteRange,
            previousRange.endOffset == currentRange.offset,
            let range = HLSByteRange(
                offset: previousRange.offset,
                length: currentRange.endOffset - previousRange.offset
            ),
            range.length <= Int64(maximumTransferBytes)
        else {
            return nil
        }
        return HLSResourceTransfer(
            url: current.url,
            byteRange: range
        )
    }
}
