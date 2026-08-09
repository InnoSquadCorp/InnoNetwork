import CommonCrypto
import Foundation
import InnoNetwork

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct HLSAES128KeySet: Sendable {
    static let empty = HLSAES128KeySet(keysByURL: [:])

    private let keysByURL: [URL: Data]

    init(keysByURL: [URL: Data]) {
        self.keysByURL = keysByURL
    }

    func key(
        for encryption: HLSAES128Encryption
    ) throws -> Data {
        guard let key = keysByURL[encryption.keyURL],
            key.count == kCCKeySizeAES128
        else {
            throw HLSDownloadError.invalidAES128Key
        }
        return key
    }

    func fingerprint(for keyURL: URL) -> String? {
        keysByURL[keyURL].map(HLSContentFingerprint.sha256)
    }
}

struct HLSAES128KeyResolver: Sendable {
    private let fetcher: HLSAES128KeyFetcher

    init(
        client: HLSHTTPClient,
        retryPolicy: (any RetryPolicy)?,
        clock: any InnoNetworkClock,
        networkMonitor: (any NetworkMonitoring)? = NetworkMonitor.shared
    ) {
        self.fetcher = HLSAES128KeyFetcher(
            client: client,
            retryPolicy: retryPolicy,
            clock: clock,
            networkMonitor: networkMonitor
        )
    }

    func resolve(
        resources: [HLSResourceTransfer]
    ) async throws -> HLSAES128KeySet {
        var keysByURL: [URL: Data] = [:]
        for resource in resources {
            try Task.checkCancellation()
            guard let keyURL = resource.encryption?.keyURL,
                keysByURL[keyURL] == nil
            else {
                continue
            }
            keysByURL[keyURL] = try await fetcher.fetch(keyURL)
        }
        return HLSAES128KeySet(keysByURL: keysByURL)
    }
}

private struct HLSAES128KeyFetcher: Sendable {
    private let client: HLSHTTPClient
    private let retryPolicy: (any RetryPolicy)?
    private let retryCoordinator: RetryCoordinator
    private let networkMonitor: (any NetworkMonitoring)?

    init(
        client: HLSHTTPClient,
        retryPolicy: (any RetryPolicy)?,
        clock: any InnoNetworkClock,
        networkMonitor: (any NetworkMonitoring)?
    ) {
        self.client = client
        self.retryPolicy = retryPolicy
        self.retryCoordinator = RetryCoordinator(
            eventHub: NetworkEventHub(),
            clock: clock
        )
        self.networkMonitor = networkMonitor
    }

    func fetch(_ keyURL: URL) async throws -> Data {
        var mutableRequest = URLRequest(url: keyURL)
        mutableRequest.timeoutInterval = 15
        mutableRequest.setValue(
            "application/octet-stream",
            forHTTPHeaderField: "Accept"
        )
        let request = mutableRequest
        let requestID = UUID()
        let result: Result<Data, HLSDownloadError>
        do {
            result = try await retryCoordinator.execute(
                retryPolicy: retryPolicy,
                networkMonitor: networkMonitor,
                requestID: requestID,
                eventObservers: client.eventObservers
            ) { retryIndex, requestID in
                do {
                    return .success(
                        try await fetchAttempt(
                            request: request,
                            requestID: requestID,
                            retryIndex: retryIndex
                        )
                    )
                } catch let error as HLSDownloadError {
                    return .failure(error)
                } catch {
                    if HLSHTTPClient.isCancellation(error) {
                        throw NetworkError.cancelled
                    }
                    if HLSHTTPClient.isBodyLimitExceeded(error) {
                        return .failure(.invalidAES128Key)
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
                throw HLSDownloadError.invalidAES128KeyResponseStatus(
                    response.statusCode
                )
            default:
                throw HLSDownloadError.wrappingTransferFailure(error)
            }
        }

        switch result {
        case .success(let key):
            return key
        case .failure(let error):
            throw error
        }
    }

    private func fetchAttempt(
        request: URLRequest,
        requestID: UUID,
        retryIndex: Int
    ) async throws -> Data {
        let transfer = try await client.transfer(
            request,
            purpose: .encryptionKey,
            maximumBytes: kCCKeySizeAES128,
            requestID: requestID,
            retryIndex: retryIndex,
            disablesCaching: true
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
            guard httpResponse.statusCode != 206 else {
                throw HLSDownloadError.invalidAES128Key
            }
        }

        var key = Data()
        key.reserveCapacity(kCCKeySizeAES128)
        for try await chunk in transfer.chunks {
            try Task.checkCancellation()
            key.append(chunk)
        }
        guard key.count == kCCKeySizeAES128 else {
            throw HLSDownloadError.invalidAES128Key
        }
        return key
    }
}

enum HLSAES128Decryptor {
    private static let inputChunkBytes = 64 * 1_024

    static func decrypt(
        inputURL: URL,
        outputURL: URL,
        key: Data,
        initializationVector: Data,
        diskCapacityGuard: HLSDiskCapacityGuard
    ) async throws {
        guard key.count == kCCKeySizeAES128,
            initializationVector.count == kCCBlockSizeAES128
        else {
            throw HLSDownloadError.invalidAES128Key
        }
        guard
            let ciphertextByteCount =
                try inputURL.resourceValues(
                    forKeys: [.fileSizeKey]
                ).fileSize,
            ciphertextByteCount > 0,
            ciphertextByteCount.isMultiple(
                of: kCCBlockSizeAES128
            )
        else {
            throw HLSDownloadError.aes128DecryptionFailed
        }

        var cryptor: CCCryptorRef?
        let createStatus = key.withUnsafeBytes { keyBytes in
            initializationVector.withUnsafeBytes { ivBytes in
                CCCryptorCreate(
                    CCOperation(kCCDecrypt),
                    CCAlgorithm(kCCAlgorithmAES),
                    CCOptions(kCCOptionPKCS7Padding),
                    keyBytes.baseAddress,
                    key.count,
                    ivBytes.baseAddress,
                    &cryptor
                )
            }
        }
        guard createStatus == kCCSuccess, let cryptor else {
            throw HLSDownloadError.aes128DecryptionFailed
        }
        defer {
            CCCryptorRelease(cryptor)
        }

        let fileManager = FileManager.default
        guard
            fileManager.createFile(
                atPath: outputURL.path,
                contents: nil
            )
        else {
            throw HLSDownloadError.internalTransferFailure(
                "A decrypted HLS resource file could not be created.",
                code: 9
            )
        }
        var completed = false
        defer {
            if !completed {
                try? fileManager.removeItem(at: outputURL)
            }
        }

        let input = try FileHandle(forReadingFrom: inputURL)
        defer {
            try? input.close()
        }
        let output = try FileHandle(forWritingTo: outputURL)
        defer {
            try? output.close()
        }

        while let chunk = try input.read(
            upToCount: inputChunkBytes
        ), !chunk.isEmpty {
            try Task.checkCancellation()
            let decrypted = try update(
                cryptor: cryptor,
                input: chunk
            )
            try await write(
                decrypted,
                to: output,
                diskCapacityGuard: diskCapacityGuard
            )
        }
        let final = try finalize(cryptor: cryptor)
        try await write(
            final,
            to: output,
            diskCapacityGuard: diskCapacityGuard
        )
        do {
            try output.synchronize()
            try output.close()
        } catch {
            throw HLSDownloadError.wrappingTransferFailure(error)
        }
        completed = true
    }

    private static func update(
        cryptor: CCCryptorRef,
        input: Data
    ) throws -> Data {
        let outputCapacity = CCCryptorGetOutputLength(
            cryptor,
            input.count,
            false
        )
        var output = Data(count: outputCapacity)
        var outputLength = 0
        let status = output.withUnsafeMutableBytes { outputBytes in
            input.withUnsafeBytes { inputBytes in
                CCCryptorUpdate(
                    cryptor,
                    inputBytes.baseAddress,
                    input.count,
                    outputBytes.baseAddress,
                    outputCapacity,
                    &outputLength
                )
            }
        }
        guard status == kCCSuccess else {
            throw HLSDownloadError.aes128DecryptionFailed
        }
        output.count = outputLength
        return output
    }

    private static func finalize(
        cryptor: CCCryptorRef
    ) throws -> Data {
        let outputCapacity = CCCryptorGetOutputLength(
            cryptor,
            0,
            true
        )
        var output = Data(count: outputCapacity)
        var outputLength = 0
        let status = output.withUnsafeMutableBytes { outputBytes in
            CCCryptorFinal(
                cryptor,
                outputBytes.baseAddress,
                outputCapacity,
                &outputLength
            )
        }
        guard status == kCCSuccess else {
            throw HLSDownloadError.aes128DecryptionFailed
        }
        output.count = outputLength
        return output
    }

    private static func write(
        _ data: Data,
        to output: FileHandle,
        diskCapacityGuard: HLSDiskCapacityGuard
    ) async throws {
        guard !data.isEmpty else {
            return
        }
        try await diskCapacityGuard.reserve(data.count)
        do {
            try output.write(contentsOf: data)
        } catch {
            await diskCapacityGuard.release(data.count)
            throw HLSDownloadError.wrappingTransferFailure(error)
        }
        await diskCapacityGuard.release(data.count)
    }
}
