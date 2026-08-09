import Foundation
import InnoNetwork

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct HLSStagedResource: Sendable {
    let index: Int
    let fileURL: URL
}

struct HLSResourceLoader: Sendable {
    private let client: HLSHTTPClient
    private let maximumMediaResourceBytes: Int
    private let retryPolicy: (any RetryPolicy)?
    private let retryCoordinator: RetryCoordinator
    private let networkMonitor: (any NetworkMonitoring)?
    private let aes128KeySet: HLSAES128KeySet
    private let pathwayID: String?
    private let contentSteering: HLSContentSteeringSettings?
    private let contentSteeringRecovery: HLSContentSteeringRecovery?

    init(
        client: HLSHTTPClient,
        maximumMediaResourceBytes: Int,
        retryPolicy: (any RetryPolicy)?,
        clock: any InnoNetworkClock = SystemClock(),
        networkMonitor: (any NetworkMonitoring)? = NetworkMonitor.shared,
        aes128KeySet: HLSAES128KeySet = .empty,
        pathwayID: String? = nil,
        contentSteering: HLSContentSteeringSettings? = nil,
        contentSteeringRecovery: HLSContentSteeringRecovery? = nil
    ) {
        self.client = client
        self.maximumMediaResourceBytes = maximumMediaResourceBytes
        self.retryPolicy = retryPolicy
        self.retryCoordinator = RetryCoordinator(
            eventHub: NetworkEventHub(),
            clock: clock
        )
        self.networkMonitor = networkMonitor
        self.aes128KeySet = aes128KeySet
        self.pathwayID = pathwayID
        self.contentSteering = contentSteering
        self.contentSteeringRecovery = contentSteeringRecovery
    }

    func stage(
        resource: HLSResourceTransfer,
        at index: Int,
        in directoryURL: URL,
        budget: HLSDownloadBudget,
        diskCapacityGuard: HLSDiskCapacityGuard
    ) async throws -> HLSStagedResource {
        var pathwayResource = HLSPathwayResource(
            pathwayID: pathwayID,
            transfer: resource,
            aes128KeySet: aes128KeySet
        )
        while true {
            await contentSteering?.emit(
                .pathwayAttempt(
                    pathwayID: pathwayResource.pathwayID,
                    phase: .mediaResource,
                    resourceIndex: index
                )
            )
            do {
                let staged = try await stage(
                    pathwayResource: pathwayResource,
                    at: index,
                    in: directoryURL,
                    budget: budget,
                    diskCapacityGuard: diskCapacityGuard
                )
                await contentSteering?.emit(
                    .pathwaySelected(
                        pathwayID: pathwayResource.pathwayID,
                        phase: .mediaResource,
                        resourceIndex: index
                    )
                )
                return staged
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as HLSDownloadError {
                await contentSteering?.emit(
                    .pathwayFailed(
                        pathwayID: pathwayResource.pathwayID,
                        phase: .mediaResource,
                        resourceIndex: index,
                        errorCode: error.code
                    )
                )
                guard
                    Self.canFailOver(after: error),
                    let contentSteeringRecovery,
                    let recoveredResource =
                        try await contentSteeringRecovery.resource(
                            at: index,
                            afterFailureOf:
                                pathwayResource.pathwayID
                        )
                else {
                    throw error
                }
                pathwayResource = recoveredResource
            }
        }
    }

    private func stage(
        pathwayResource: HLSPathwayResource,
        at index: Int,
        in directoryURL: URL,
        budget: HLSDownloadBudget,
        diskCapacityGuard: HLSDiskCapacityGuard
    ) async throws -> HLSStagedResource {
        let resource = pathwayResource.transfer
        var mutableRequest = URLRequest(url: resource.url)
        mutableRequest.timeoutInterval = 60
        mutableRequest.setValue("*/*", forHTTPHeaderField: "Accept")
        if let byteRange = resource.byteRange {
            guard byteRange.length <= Int64(maximumMediaResourceBytes) else {
                throw HLSDownloadError.mediaResourceTooLarge(
                    limit: maximumMediaResourceBytes
                )
            }
            let inclusiveEnd = byteRange.endOffset - 1
            mutableRequest.setValue(
                "bytes=\(byteRange.offset)-\(inclusiveEnd)",
                forHTTPHeaderField: "Range"
            )
            mutableRequest.setValue(
                "identity",
                forHTTPHeaderField: "Accept-Encoding"
            )
        }
        let request = mutableRequest
        let requestID = UUID()
        let result: Result<HLSStagedResource, HLSDownloadError>
        do {
            result = try await retryCoordinator.execute(
                retryPolicy: retryPolicy,
                networkMonitor: networkMonitor,
                requestID: requestID,
                eventObservers: client.eventObservers
            ) { retryIndex, requestID in
                await budget.beginAttempt(forResourceAt: index)
                do {
                    return .success(
                        try await stageAttempt(
                            request: request,
                            byteRange: resource.byteRange,
                            encryption: resource.encryption,
                            index: index,
                            directoryURL: directoryURL,
                            budget: budget,
                            diskCapacityGuard: diskCapacityGuard,
                            requestID: requestID,
                            retryIndex: retryIndex,
                            aes128KeySet:
                                pathwayResource.aes128KeySet
                        )
                    )
                } catch let error as HLSDownloadError {
                    await budget.discardAttempt(forResourceAt: index)
                    return .failure(error)
                } catch {
                    await budget.discardAttempt(forResourceAt: index)
                    if HLSHTTPClient.isCancellation(error) {
                        throw NetworkError.cancelled
                    }
                    if HLSHTTPClient.isBodyLimitExceeded(error) {
                        if resource.byteRange != nil {
                            return .failure(.invalidByteRangeResponse)
                        }
                        return .failure(
                            .mediaResourceTooLarge(
                                limit: maximumMediaResourceBytes
                            )
                        )
                    }
                    let networkError =
                        error as? NetworkError
                        ?? NetworkError.mapTransportError(error)
                    throw RequestExecutionFailure(
                        error: networkError,
                        request: request
                    )
                }
            }
        } catch let error as NetworkError {
            switch error {
            case .cancelled:
                throw CancellationError()
            case .statusCode(let response):
                throw HLSDownloadError.invalidMediaResponseStatus(
                    response.statusCode
                )
            default:
                throw HLSDownloadError.wrappingTransferFailure(error)
            }
        }

        switch result {
        case .success(let stagedResource):
            return stagedResource
        case .failure(let error):
            throw error
        }
    }

    private func stageAttempt(
        request: URLRequest,
        byteRange: HLSByteRange?,
        encryption: HLSAES128Encryption?,
        index: Int,
        directoryURL: URL,
        budget: HLSDownloadBudget,
        diskCapacityGuard: HLSDiskCapacityGuard,
        requestID: UUID,
        retryIndex: Int,
        aes128KeySet: HLSAES128KeySet
    ) async throws -> HLSStagedResource {
        try Task.checkCancellation()
        let transferByteLimit =
            byteRange.map { Int($0.length) }
            ?? maximumMediaResourceBytes
        let transfer = try await client.transfer(
            request,
            purpose: .mediaResource,
            resourceIndex: index,
            maximumBytes: transferByteLimit,
            requestID: requestID,
            retryIndex: retryIndex
        )
        defer {
            transfer.cancel()
        }

        if let httpResponse = transfer.response as? HTTPURLResponse {
            guard (200..<300).contains(httpResponse.statusCode) else {
                throw NetworkError.statusCode(
                    Response(
                        statusCode: httpResponse.statusCode,
                        data: Data(),
                        request: request,
                        response: httpResponse,
                        kind: .headersOnly
                    )
                )
            }
            if let byteRange {
                guard httpResponse.statusCode == 206,
                    let contentRange = httpResponse.value(
                        forHTTPHeaderField: "Content-Range"
                    ),
                    Self.matches(
                        contentRange: contentRange,
                        expected: byteRange
                    ),
                    httpResponse.expectedContentLength < 0
                        || httpResponse.expectedContentLength
                            == byteRange.length
                else {
                    throw HLSDownloadError.invalidByteRangeResponse
                }
            } else if httpResponse.statusCode == 206 {
                throw HLSDownloadError.invalidByteRangeResponse
            }
        }

        let expectedBytes =
            byteRange?.length
            ?? transfer.response.expectedContentLength
        if expectedBytes > Int64(maximumMediaResourceBytes) {
            throw HLSDownloadError.mediaResourceTooLarge(
                limit: maximumMediaResourceBytes
            )
        }
        try await budget.registerExpectedBytes(
            expectedBytes,
            forResourceAt: index
        )
        try await diskCapacityGuard.validate(
            additionalRequiredCapacity: max(0, expectedBytes)
        )

        let stagedURL = directoryURL.appendingPathComponent(
            "\(index)-\(UUID().uuidString).resource"
        )
        let fileManager = FileManager.default
        guard fileManager.createFile(atPath: stagedURL.path, contents: nil)
        else {
            throw HLSDownloadError.internalTransferFailure(
                "A staged HLS resource file could not be created.",
                code: 2
            )
        }

        var completed = false
        var decryptedURL: URL?
        defer {
            if !completed {
                try? fileManager.removeItem(at: stagedURL)
                if let decryptedURL {
                    try? fileManager.removeItem(at: decryptedURL)
                }
            }
        }

        let fileHandle: FileHandle
        do {
            fileHandle = try FileHandle(forWritingTo: stagedURL)
        } catch {
            throw HLSDownloadError.wrappingTransferFailure(error)
        }
        defer {
            try? fileHandle.close()
        }

        var receivedBytes: Int64 = 0
        do {
            for try await chunk in transfer.chunks {
                try Task.checkCancellation()
                try await diskCapacityGuard.reserve(chunk.count)
                do {
                    try await recordAndWrite(
                        chunk,
                        to: fileHandle,
                        resourceIndex: index,
                        budget: budget
                    )
                } catch {
                    await diskCapacityGuard.release(chunk.count)
                    throw error
                }
                await diskCapacityGuard.release(chunk.count)
                let (nextReceivedBytes, overflow) =
                    receivedBytes.addingReportingOverflow(
                        Int64(chunk.count)
                    )
                guard !overflow else {
                    throw HLSDownloadError.invalidByteRangeResponse
                }
                receivedBytes = nextReceivedBytes
            }
            if let byteRange, receivedBytes != byteRange.length {
                throw HLSDownloadError.invalidByteRangeResponse
            }
            do {
                try fileHandle.synchronize()
                try fileHandle.close()
            } catch {
                throw HLSDownloadError.wrappingTransferFailure(error)
            }
        } catch {
            if HLSHTTPClient.isCancellation(error) {
                throw CancellationError()
            }
            if HLSHTTPClient.isBodyLimitExceeded(error) {
                if byteRange != nil {
                    throw HLSDownloadError.invalidByteRangeResponse
                }
                throw HLSDownloadError.mediaResourceTooLarge(
                    limit: maximumMediaResourceBytes
                )
            }
            throw error
        }

        let outputURL: URL
        if let encryption {
            let decryptedResourceURL =
                directoryURL.appendingPathComponent(
                    "\(index)-\(UUID().uuidString).decrypted"
                )
            decryptedURL = decryptedResourceURL
            try await HLSAES128Decryptor.decrypt(
                inputURL: stagedURL,
                outputURL: decryptedResourceURL,
                key: try aes128KeySet.key(for: encryption),
                initializationVector:
                    encryption.initializationVector,
                diskCapacityGuard: diskCapacityGuard
            )
            guard
                let plaintextByteCount =
                    try decryptedResourceURL.resourceValues(
                        forKeys: [.fileSizeKey]
                    ).fileSize
            else {
                throw HLSDownloadError.aes128DecryptionFailed
            }
            try await budget.replaceRetainedBytes(
                with: Int64(plaintextByteCount),
                forResourceAt: index
            )
            try fileManager.removeItem(at: stagedURL)
            outputURL = decryptedResourceURL
        } else {
            outputURL = stagedURL
        }

        completed = true
        return HLSStagedResource(index: index, fileURL: outputURL)
    }

    private func recordAndWrite(
        _ chunk: Data,
        to fileHandle: FileHandle,
        resourceIndex: Int,
        budget: HLSDownloadBudget
    ) async throws {
        try await budget.recordDownloadedBytes(
            chunk.count,
            forResourceAt: resourceIndex
        )
        do {
            try fileHandle.write(contentsOf: chunk)
        } catch {
            throw HLSDownloadError.wrappingTransferFailure(error)
        }
    }

    private static func matches(
        contentRange value: String,
        expected byteRange: HLSByteRange
    ) -> Bool {
        let normalized = value.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard normalized.lowercased().hasPrefix("bytes ") else {
            return false
        }
        let fields = normalized.dropFirst("bytes ".count).split(
            separator: "/",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard fields.count == 2 else {
            return false
        }
        let interval = fields[0].split(
            separator: "-",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard interval.count == 2,
            let lowerBound = Int64(interval[0]),
            let upperBound = Int64(interval[1]),
            lowerBound == byteRange.offset,
            upperBound == byteRange.endOffset - 1
        else {
            return false
        }
        if fields[1] == "*" {
            return true
        }
        guard let totalLength = Int64(fields[1]) else {
            return false
        }
        return totalLength > upperBound
    }

    private static func canFailOver(
        after error: HLSDownloadError
    ) -> Bool {
        switch error {
        case .transferFailed:
            return true
        case .invalidMediaResponseStatus(let statusCode):
            return statusCode == 404
                || statusCode == 408
                || statusCode == 429
                || (500...599).contains(statusCode)
        default:
            return false
        }
    }
}
