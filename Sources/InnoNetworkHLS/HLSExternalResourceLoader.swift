import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct HLSExternalResourceLoader: Sendable {
    private let client: HLSHTTPClient
    private let requestTimeout: TimeInterval

    init(
        client: HLSHTTPClient,
        requestTimeout: TimeInterval
    ) {
        self.client = client
        self.requestTimeout = requestTimeout
    }

    func load(
        from url: URL,
        purpose: HLSRequestPurpose,
        accept: String,
        maximumBytes: Int
    ) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = requestTimeout
        request.setValue(accept, forHTTPHeaderField: "Accept")

        let transfer: HLSHTTPTransfer
        do {
            transfer = try await client.transfer(
                request,
                purpose: purpose,
                maximumBytes: maximumBytes
            )
        } catch {
            throw Self.map(error, maximumBytes: maximumBytes)
        }
        defer {
            transfer.cancel()
        }
        if let response = transfer.response as? HTTPURLResponse,
            !(200..<300).contains(response.statusCode)
        {
            throw HLSExternalResourceError.invalidResponseStatus(
                response.statusCode
            )
        }

        var data = Data()
        let expectedLength = transfer.response.expectedContentLength
        if expectedLength > Int64(maximumBytes) {
            throw HLSExternalResourceError.responseTooLarge(
                limit: maximumBytes
            )
        }
        if expectedLength > 0,
            let capacity = Int(exactly: expectedLength)
        {
            data.reserveCapacity(capacity)
        }
        do {
            for try await chunk in transfer.chunks {
                try Task.checkCancellation()
                data.append(chunk)
            }
        } catch {
            throw Self.map(error, maximumBytes: maximumBytes)
        }
        return data
    }

    private static func map(
        _ error: Error,
        maximumBytes: Int
    ) -> any Error {
        if HLSHTTPClient.isCancellation(error) {
            return CancellationError()
        }
        if HLSHTTPClient.isBodyLimitExceeded(error) {
            return HLSExternalResourceError.responseTooLarge(
                limit: maximumBytes
            )
        }
        return error
    }
}
