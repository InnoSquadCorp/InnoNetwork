import Foundation
import InnoNetworkHLS

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum HLSLiveDVRResourceLoadError: Error {
    case bodyLimitExceeded
    case retainedLimitExceeded
    case invalidByteRangeResponse
    case invalidResponseStatus(Int)
    case emptyResponse
    case transferFailed
}

struct HLSLiveDVRResourceLoader: Sendable {
    let client: HLSHTTPClient
    let requestTimeout: TimeInterval

    func load(
        from sourceURL: URL,
        byteRange: HLSByteRange?,
        openEndedByteRangeStart: Int64? = nil,
        encryption: HLSLiveAES128Encryption?,
        purpose: HLSRequestPurpose = .mediaResource,
        resourceIndex: Int?,
        maximumBytes: Int,
        maximumRetainedBytes: Int,
        keyCache: HLSAES128KeyCache,
        diskCapacityGuard: HLSDiskCapacityGuard,
        destinationURL: URL
    ) async throws -> Int64 {
        guard byteRange == nil || openEndedByteRangeStart == nil,
            openEndedByteRangeStart.map({ $0 >= 0 }) ?? true
        else {
            throw HLSLiveDVRResourceLoadError
                .invalidByteRangeResponse
        }
        let decryptionKey: Data?
        if let encryption {
            decryptionKey = try await keyCache.key(
                for: encryption.keyURL
            )
        } else {
            decryptionKey = nil
        }

        var request = URLRequest(url: sourceURL)
        request.timeoutInterval = requestTimeout
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        if let byteRange {
            let (endOffset, overflow) =
                byteRange.offset.addingReportingOverflow(
                    byteRange.length - 1
                )
            guard !overflow else {
                throw HLSLiveDVRResourceLoadError
                    .invalidByteRangeResponse
            }
            request.setValue(
                "bytes=\(byteRange.offset)-\(endOffset)",
                forHTTPHeaderField: "Range"
            )
            request.setValue(
                "identity",
                forHTTPHeaderField: "Accept-Encoding"
            )
        } else if let openEndedByteRangeStart {
            request.setValue(
                "bytes=\(openEndedByteRangeStart)-",
                forHTTPHeaderField: "Range"
            )
            request.setValue(
                "identity",
                forHTTPHeaderField: "Accept-Encoding"
            )
        }

        let transfer: HLSHTTPTransfer
        do {
            transfer = try await client.transfer(
                request,
                purpose: purpose,
                resourceIndex: resourceIndex,
                maximumBytes: maximumBytes
            )
        } catch {
            if HLSHTTPClient.isCancellation(error) {
                throw CancellationError()
            }
            if HLSHTTPClient.isBodyLimitExceeded(error) {
                throw HLSLiveDVRResourceLoadError.bodyLimitExceeded
            }
            throw HLSLiveDVRResourceLoadError.transferFailed
        }
        defer {
            transfer.cancel()
        }
        try validate(
            transfer.response,
            byteRange: byteRange,
            openEndedByteRangeStart: openEndedByteRangeStart
        )

        let fileManager = FileManager.default
        let stagedURL =
            encryption == nil
            ? destinationURL
            : destinationURL
                .deletingLastPathComponent()
                .appendingPathComponent(
                    ".\(destinationURL.lastPathComponent)."
                        + "\(UUID().uuidString).ciphertext"
                )
        let expectedBytes =
            byteRange?.length
            ?? max(0, transfer.response.expectedContentLength)
        let capacityMultiplier: Int64 = encryption == nil ? 1 : 2
        let (requiredCapacity, capacityOverflow) =
            expectedBytes.multipliedReportingOverflow(
                by: capacityMultiplier
            )
        try await diskCapacityGuard.validate(
            additionalRequiredCapacity:
                capacityOverflow ? .max : requiredCapacity
        )
        guard
            fileManager.createFile(
                atPath: stagedURL.path,
                contents: nil
            )
        else {
            throw HLSLiveDVRError.storageFailed
        }
        var completed = false
        defer {
            if !completed {
                try? fileManager.removeItem(at: stagedURL)
                if stagedURL != destinationURL {
                    try? fileManager.removeItem(at: destinationURL)
                }
            }
        }

        let fileHandle: FileHandle
        do {
            fileHandle = try FileHandle(
                forWritingTo: stagedURL
            )
        } catch {
            throw HLSLiveDVRError.storageFailed
        }
        defer {
            try? fileHandle.close()
        }

        var byteCount: Int64 = 0
        do {
            for try await chunk in transfer.chunks {
                try Task.checkCancellation()
                let (nextByteCount, overflow) =
                    byteCount.addingReportingOverflow(
                        Int64(chunk.count)
                    )
                guard
                    !overflow,
                    nextByteCount <= Int64(maximumBytes)
                else {
                    throw HLSLiveDVRResourceLoadError
                        .bodyLimitExceeded
                }
                try await diskCapacityGuard.reserve(chunk.count)
                do {
                    try fileHandle.write(contentsOf: chunk)
                } catch {
                    await diskCapacityGuard.release(chunk.count)
                    throw HLSLiveDVRError.storageFailed
                }
                await diskCapacityGuard.release(chunk.count)
                byteCount = nextByteCount
            }
            do {
                try fileHandle.synchronize()
                try fileHandle.close()
            } catch {
                throw HLSLiveDVRError.storageFailed
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as HLSLiveDVRResourceLoadError {
            throw error
        } catch let error as HLSLiveDVRError {
            throw error
        } catch let error as HLSDownloadError {
            throw error
        } catch {
            if HLSHTTPClient.isCancellation(error) {
                throw CancellationError()
            }
            if HLSHTTPClient.isBodyLimitExceeded(error) {
                throw HLSLiveDVRResourceLoadError
                    .bodyLimitExceeded
            }
            throw HLSLiveDVRResourceLoadError.transferFailed
        }

        guard byteCount > 0 else {
            throw HLSLiveDVRResourceLoadError.emptyResponse
        }
        if let byteRange,
            byteCount != byteRange.length
        {
            throw HLSLiveDVRResourceLoadError
                .invalidByteRangeResponse
        }
        if let encryption, let decryptionKey {
            try await HLSAES128Decryptor.decrypt(
                inputURL: stagedURL,
                outputURL: destinationURL,
                key: decryptionKey,
                initializationVector:
                    encryption.initializationVector,
                diskCapacityGuard: diskCapacityGuard
            )
            guard
                let plaintextByteCount =
                    try destinationURL
                    .resourceValues(forKeys: [.fileSizeKey])
                    .fileSize,
                plaintextByteCount > 0
            else {
                throw HLSDownloadError.aes128DecryptionFailed
            }
            guard plaintextByteCount <= maximumRetainedBytes else {
                throw HLSLiveDVRResourceLoadError
                    .retainedLimitExceeded
            }
            do {
                try fileManager.removeItem(at: stagedURL)
            } catch {
                throw HLSLiveDVRError.storageFailed
            }
            byteCount = Int64(plaintextByteCount)
        }
        completed = true
        return byteCount
    }

    private func validate(
        _ response: URLResponse,
        byteRange: HLSByteRange?,
        openEndedByteRangeStart: Int64?
    ) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            return
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw
                HLSLiveDVRResourceLoadError
                .invalidResponseStatus(httpResponse.statusCode)
        }
        if let byteRange {
            guard
                httpResponse.statusCode == 206,
                let contentRange = httpResponse.value(
                    forHTTPHeaderField: "Content-Range"
                ),
                Self.matches(
                    contentRange: contentRange,
                    byteRange: byteRange
                ),
                httpResponse.expectedContentLength < 0
                    || httpResponse.expectedContentLength
                        == byteRange.length
            else {
                throw HLSLiveDVRResourceLoadError
                    .invalidByteRangeResponse
            }
        } else if let openEndedByteRangeStart {
            guard
                httpResponse.statusCode == 206,
                let contentRange = httpResponse.value(
                    forHTTPHeaderField: "Content-Range"
                ),
                Self.matches(
                    contentRange: contentRange,
                    openEndedByteRangeStart:
                        openEndedByteRangeStart,
                    expectedContentLength:
                        httpResponse.expectedContentLength
                )
            else {
                throw HLSLiveDVRResourceLoadError
                    .invalidByteRangeResponse
            }
        } else if httpResponse.statusCode == 206 {
            throw HLSLiveDVRResourceLoadError
                .invalidByteRangeResponse
        }
    }

    static func matches(
        contentRange: String,
        byteRange: HLSByteRange
    ) -> Bool {
        let components = contentRange.split(
            separator: " ",
            maxSplits: 1
        )
        guard
            components.count == 2,
            components[0].lowercased() == "bytes"
        else {
            return false
        }
        let interval = components[1].split(
            separator: "/",
            maxSplits: 1
        ).first
        let bounds = interval?.split(
            separator: "-",
            maxSplits: 1
        )
        guard
            let bounds,
            bounds.count == 2,
            let lower = Int64(bounds[0]),
            let upper = Int64(bounds[1])
        else {
            return false
        }
        let (expectedUpper, overflow) =
            byteRange.offset.addingReportingOverflow(
                byteRange.length - 1
            )
        return !overflow
            && lower == byteRange.offset
            && upper == expectedUpper
    }

    static func matches(
        contentRange: String,
        openEndedByteRangeStart: Int64,
        expectedContentLength: Int64
    ) -> Bool {
        let components = contentRange.split(
            separator: " ",
            maxSplits: 1
        )
        guard
            components.count == 2,
            components[0].lowercased() == "bytes"
        else {
            return false
        }
        let interval = components[1].split(
            separator: "/",
            maxSplits: 1
        ).first
        let bounds = interval?.split(
            separator: "-",
            maxSplits: 1
        )
        guard let bounds,
            bounds.count == 2,
            let lower = Int64(bounds[0]),
            let upper = Int64(bounds[1]),
            lower == openEndedByteRangeStart,
            upper >= lower
        else {
            return false
        }
        let (distance, subtractionOverflow) =
            upper.subtractingReportingOverflow(lower)
        let (length, additionOverflow) =
            distance.addingReportingOverflow(1)
        return !subtractionOverflow
            && !additionOverflow
            && (expectedContentLength < 0
                || expectedContentLength == length)
    }
}
