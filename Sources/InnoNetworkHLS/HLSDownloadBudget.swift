import Foundation

actor HLSDownloadBudget {
    private let maximumTotalBytes: Int64
    private let resourceCount: Int
    private let progressHandler: @Sendable (HLSDownloadProgress) -> Void

    private var totalBytesWritten: Int64 = 0
    private var registeredResources: Set<Int> = []
    private var expectedBytesByResource: [Int: Int64] = [:]
    private var downloadedBytesByResource: [Int: Int64] = [:]

    init(
        maximumTotalBytes: Int64,
        resourceCount: Int,
        initialBytesWritten: Int64 = 0,
        progressHandler:
            @escaping @Sendable (HLSDownloadProgress) -> Void
    ) {
        self.maximumTotalBytes = maximumTotalBytes
        self.resourceCount = resourceCount
        self.progressHandler = progressHandler
        self.totalBytesWritten = initialBytesWritten
    }

    func registerExpectedBytes(
        _ expectedBytes: Int64,
        forResourceAt index: Int
    ) throws {
        registeredResources.insert(index)
        if expectedBytes >= 0 {
            expectedBytesByResource[index] = expectedBytes
            let expectedTotal = try knownExpectedTotal()
            guard expectedTotal <= maximumTotalBytes else {
                throw HLSDownloadError.totalDownloadTooLarge(
                    limit: maximumTotalBytes
                )
            }
        } else {
            expectedBytesByResource.removeValue(forKey: index)
        }
        emitProgress(bytesWritten: 0)
    }

    func beginAttempt(forResourceAt index: Int) {
        discardAttempt(forResourceAt: index)
    }

    func registerRetainedBytes(
        _ byteCount: Int64,
        forResourceAt index: Int
    ) throws {
        guard byteCount >= 0 else {
            throw HLSDownloadError.internalTransferFailure(
                "A retained HLS resource reported a negative byte count.",
                code: 13
            )
        }
        registeredResources.insert(index)
        expectedBytesByResource[index] = byteCount
        guard try knownExpectedTotal() <= maximumTotalBytes else {
            throw HLSDownloadError.totalDownloadTooLarge(
                limit: maximumTotalBytes
            )
        }
        emitProgress(bytesWritten: 0)
    }

    func discardAttempt(forResourceAt index: Int) {
        let previousBytes = downloadedBytesByResource[index] ?? 0
        downloadedBytesByResource[index] = 0
        guard previousBytes > 0 else {
            return
        }
        totalBytesWritten -= previousBytes
        emitProgress(bytesWritten: 0)
    }

    func recordDownloadedBytes(
        _ byteCount: Int,
        forResourceAt index: Int
    ) throws {
        let bytes = Int64(byteCount)
        let (nextTotal, overflow) = totalBytesWritten.addingReportingOverflow(
            bytes
        )
        guard !overflow, nextTotal <= maximumTotalBytes else {
            throw HLSDownloadError.totalDownloadTooLarge(
                limit: maximumTotalBytes
            )
        }
        let currentResourceBytes = downloadedBytesByResource[index] ?? 0
        let (nextResourceBytes, resourceOverflow) =
            currentResourceBytes.addingReportingOverflow(bytes)
        guard !resourceOverflow else {
            throw HLSDownloadError.totalDownloadTooLarge(
                limit: maximumTotalBytes
            )
        }
        downloadedBytesByResource[index] = nextResourceBytes
        totalBytesWritten = nextTotal
        emitProgress(bytesWritten: bytes)
    }

    func replaceRetainedBytes(
        with byteCount: Int64,
        forResourceAt index: Int
    ) throws {
        guard byteCount >= 0 else {
            throw HLSDownloadError.internalTransferFailure(
                "An HLS resource reported a negative retained byte count.",
                code: 10
            )
        }
        let previousBytes = downloadedBytesByResource[index] ?? 0
        let withoutPrevious = totalBytesWritten - previousBytes
        let (nextTotal, overflow) =
            withoutPrevious.addingReportingOverflow(byteCount)
        guard !overflow, nextTotal <= maximumTotalBytes else {
            throw HLSDownloadError.totalDownloadTooLarge(
                limit: maximumTotalBytes
            )
        }
        downloadedBytesByResource[index] = byteCount
        expectedBytesByResource[index] = byteCount
        totalBytesWritten = nextTotal
        emitProgress(bytesWritten: 0)
    }

    func finish() {
        progressHandler(
            HLSDownloadProgress(
                bytesWritten: 0,
                totalBytesWritten: totalBytesWritten,
                totalBytesExpectedToWrite: totalBytesWritten
            )
        )
    }

    private func knownExpectedTotal() throws -> Int64 {
        var total: Int64 = 0
        for expectedBytes in expectedBytesByResource.values {
            let (nextTotal, overflow) = total.addingReportingOverflow(
                expectedBytes
            )
            guard !overflow else {
                throw HLSDownloadError.totalDownloadTooLarge(
                    limit: maximumTotalBytes
                )
            }
            total = nextTotal
        }
        return total
    }

    private func emitProgress(bytesWritten: Int64) {
        let expectedTotal: Int64?
        if registeredResources.count == resourceCount,
            expectedBytesByResource.count == resourceCount,
            let knownTotal = try? knownExpectedTotal()
        {
            expectedTotal = knownTotal
        } else {
            expectedTotal = nil
        }
        progressHandler(
            HLSDownloadProgress(
                bytesWritten: bytesWritten,
                totalBytesWritten: totalBytesWritten,
                totalBytesExpectedToWrite: expectedTotal
            )
        )
    }
}
