import Foundation
import InnoNetwork

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Fetches and parses bounded UTF-8 HLS playlists.
public struct PlaylistResolver: Sendable {
    private static let defaultMaximumPlaylistBytes = 2 * 1_024 * 1_024

    package let client: HLSHTTPClient
    private let maximumPlaylistBytes: Int

    /// Creates an HLS playlist resolver backed by `URLSession.shared`.
    public init() {
        self.init(
            client: HLSHTTPClient(
                session: .shared,
                requestContext: NetworkRequestContext(),
                requestAdapter: { $0 }
            ),
            maximumPlaylistBytes: Self.defaultMaximumPlaylistBytes
        )
    }

    /// Creates an HLS playlist resolver with caller-owned transport policy.
    ///
    /// - Parameters:
    ///   - session: The URL session used for playlist requests.
    ///   - requestContext: InnoNetwork trust, redirect, and metrics policy
    ///     applied to every playlist request.
    ///   - requestAdapter: An async adapter for authentication or custom
    ///     request headers.
    public init(
        session: URLSession,
        requestContext: NetworkRequestContext = NetworkRequestContext(),
        requestAdapter:
            @escaping @Sendable (URLRequest) async throws -> URLRequest = {
                $0
            }
    ) {
        self.init(
            client: HLSHTTPClient(
                session: session,
                requestContext: requestContext,
                requestAdapter: requestAdapter
            ),
            maximumPlaylistBytes: Self.defaultMaximumPlaylistBytes
        )
    }

    /// Creates an HLS playlist resolver with purpose-aware request policy.
    public init(
        session: URLSession,
        requestContext: NetworkRequestContext = NetworkRequestContext(),
        requestPolicy: HLSRequestPolicy
    ) {
        self.init(
            client: HLSHTTPClient(
                session: session,
                requestContext: requestContext,
                requestPolicy: requestPolicy
            ),
            maximumPlaylistBytes: Self.defaultMaximumPlaylistBytes
        )
    }

    init(
        client: HLSHTTPClient,
        maximumPlaylistBytes: Int = Self.defaultMaximumPlaylistBytes
    ) {
        self.client = client
        self.maximumPlaylistBytes = maximumPlaylistBytes
    }

    /// Fetches and parses an HLS playlist.
    ///
    /// The resolver reads only the bounded playlist document. Media resources
    /// are fetched later by ``HLSDownloader``.
    public func resolve(from sourceURL: URL) async throws -> HLSPlaylist {
        try await resolveDocument(from: sourceURL).playlist
    }

    func resolveDocument(
        from sourceURL: URL,
        multivariantVariables: [String: String]? = nil,
        purpose: HLSRequestPurpose = .entryPlaylist,
        requestTimeout: TimeInterval = 15,
        disablesCaching: Bool = false
    ) async throws -> HLSResolvedPlaylistDocument {
        var request = URLRequest(url: sourceURL)
        request.timeoutInterval = requestTimeout
        request.setValue(
            "application/vnd.apple.mpegurl, application/x-mpegURL",
            forHTTPHeaderField: "Accept"
        )

        let transfer: HLSHTTPTransfer
        do {
            transfer = try await client.transfer(
                request,
                purpose: purpose,
                maximumBytes: maximumPlaylistBytes,
                disablesCaching: disablesCaching
            )
        } catch {
            if HLSHTTPClient.isCancellation(error) {
                throw CancellationError()
            }
            if HLSHTTPClient.isBodyLimitExceeded(error) {
                throw HLSDownloadError.playlistTooLarge(
                    limit: maximumPlaylistBytes
                )
            }
            throw error
        }
        defer {
            transfer.cancel()
        }

        if let httpResponse = transfer.response as? HTTPURLResponse,
            !(200..<300).contains(httpResponse.statusCode)
        {
            throw HLSDownloadError.invalidResponseStatus(
                httpResponse.statusCode
            )
        }

        var data = Data()
        data.reserveCapacity(
            min(
                maximumPlaylistBytes,
                max(0, Int(transfer.response.expectedContentLength))
            )
        )
        do {
            for try await chunk in transfer.chunks {
                try Task.checkCancellation()
                data.append(chunk)
            }
        } catch {
            if HLSHTTPClient.isCancellation(error) {
                throw CancellationError()
            }
            if HLSHTTPClient.isBodyLimitExceeded(error) {
                throw HLSDownloadError.playlistTooLarge(
                    limit: maximumPlaylistBytes
                )
            }
            throw error
        }
        guard let playlist = String(data: data, encoding: .utf8) else {
            throw HLSDownloadError.invalidPlaylist
        }

        let expansion = try HLSVariableSubstituter.expand(
            playlist,
            sourceURL: transfer.finalURL,
            multivariantVariables: multivariantVariables,
            maximumBytes: maximumPlaylistBytes
        )
        let resolvedPlaylist = try HLSPlaylistDocumentParser.parse(
            expansion.contents,
            relativeTo: transfer.finalURL,
            expansion: expansion
        )
        return HLSResolvedPlaylistDocument(
            playlist: resolvedPlaylist,
            identity: HLSContentIdentity(
                finalURL: transfer.finalURL,
                playlistData: data,
                response: transfer.response
            ),
            contents: playlist,
            variables: expansion.variables
        )
    }

    /// Parses an HLS playlist and resolves variant URLs relative to its source.
    public func resolve(
        _ playlist: String,
        relativeTo sourceURL: URL
    ) throws -> HLSPlaylist {
        try validateRawPlaylistSize(playlist)
        let expansion = try HLSVariableSubstituter.expand(
            playlist,
            sourceURL: sourceURL,
            multivariantVariables: nil,
            maximumBytes: maximumPlaylistBytes
        )
        return try HLSPlaylistDocumentParser.parse(
            expansion.contents,
            relativeTo: sourceURL,
            expansion: expansion
        )
    }

    func validateRawPlaylistSize(
        _ playlist: String
    ) throws {
        guard playlist.utf8.count <= maximumPlaylistBytes else {
            throw HLSDownloadError.playlistTooLarge(
                limit: maximumPlaylistBytes
            )
        }
    }

}
