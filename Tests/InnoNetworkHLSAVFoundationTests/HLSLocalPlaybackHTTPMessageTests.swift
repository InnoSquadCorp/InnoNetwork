#if canImport(AVFoundation) && canImport(Network)
import Foundation
import Testing

@testable import InnoNetworkHLSAVFoundation

@Suite("Local HLS HTTP messages")
struct HLSLocalPlaybackHTTPMessageTests {
    @Test("GET, HEAD, and a single range are parsed")
    func parsesSupportedRequests() throws {
        let get = try request(
            "GET /token/index.m3u8 HTTP/1.1\r\nHost: localhost\r\n\r\n"
        )
        #expect(get.method == .get)
        #expect(get.target == "/token/index.m3u8")
        #expect(
            try get.range.resolve(fileSize: 12)
                == HLSLocalPlaybackResolvedRange(
                    start: 0,
                    length: 12,
                    fileSize: 12,
                    isPartial: false
                )
        )

        let head = try request(
            "HEAD /token/index.m3u8 HTTP/1.0\r\nRange: bytes=-4\r\n\r\n"
        )
        #expect(head.method == .head)
        #expect(
            try head.range.resolve(fileSize: 12)
                == HLSLocalPlaybackResolvedRange(
                    start: 8,
                    length: 4,
                    fileSize: 12,
                    isPartial: true
                )
        )
    }

    @Test("closed and open ranges clamp only at the file boundary")
    func resolvesRangeBoundaries() throws {
        #expect(
            try HLSLocalPlaybackRequestedRange(
                headerValue: "bytes=2-99"
            ).resolve(fileSize: 10)
                == HLSLocalPlaybackResolvedRange(
                    start: 2,
                    length: 8,
                    fileSize: 10,
                    isPartial: true
                )
        )
        #expect(
            try HLSLocalPlaybackRequestedRange(
                headerValue: "bytes=4-"
            ).resolve(fileSize: 10)
                == HLSLocalPlaybackResolvedRange(
                    start: 4,
                    length: 6,
                    fileSize: 10,
                    isPartial: true
                )
        )
    }

    @Test("unsupported methods and invalid ranges fail deterministically")
    func rejectsInvalidRequests() {
        #expect(throws: HLSLocalPlaybackHTTPError.methodNotAllowed) {
            _ = try request(
                "POST /token/index.m3u8 HTTP/1.1\r\nHost: localhost\r\n\r\n"
            )
        }
        #expect(throws: HLSLocalPlaybackHTTPError.badRequest) {
            _ = try request(
                "GET /token/index.m3u8 HTTP/1.1\r\nRange: bytes=0-1\r\nRange: bytes=2-3\r\n\r\n"
            )
        }
        for value in ["bytes=", "bytes=-0", "bytes=3-2", "bytes=0-1,3-4"] {
            #expect(
                throws: HLSLocalPlaybackHTTPError.rangeNotSatisfiable
            ) {
                _ = try HLSLocalPlaybackRequestedRange(
                    headerValue: value
                )
            }
        }
        #expect(
            throws: HLSLocalPlaybackHTTPError.rangeNotSatisfiable
        ) {
            _ = try HLSLocalPlaybackRequestedRange(
                headerValue: "bytes=10-"
            ).resolve(fileSize: 10)
        }
    }

    private func request(
        _ header: String
    ) throws -> HLSLocalPlaybackHTTPRequest {
        try HLSLocalPlaybackHTTPRequest(header: Data(header.utf8))
    }
}
#endif
