import Foundation
import Testing

@testable import InnoNetworkHLS

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@Suite("HLS HTTP response freshness")
struct HLSHTTPResponseFreshnessTests {
    @Test("valid HTTP dates and age become typed values")
    func parsesFreshnessHeaders() throws {
        let url = try #require(
            URL(string: "https://media.example/live.m3u8")
        )
        let response = try #require(
            HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: [
                    "Date": "Thu, 01 Jan 1970 00:01:40 GMT",
                    "Last-Modified": "Thu, 01 Jan 1970 00:01:00 GMT",
                    "Age": "5",
                ]
            )
        )

        let freshness = HLSHTTPResponseFreshness(response: response)

        #expect(
            freshness.responseDate
                == Date(timeIntervalSince1970: 100)
        )
        #expect(
            freshness.lastModified
                == Date(timeIntervalSince1970: 60)
        )
        #expect(freshness.reportedAge == 5)
    }

    @Test("malformed or non-GMT freshness headers are ignored")
    func ignoresInvalidFreshnessHeaders() throws {
        let url = try #require(
            URL(string: "https://media.example/live.m3u8")
        )
        let response = try #require(
            HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: [
                    "Date": "Thu, 01 Jan 1970 00:01:40 UTC",
                    "Last-Modified": "invalid",
                    "Age": "-1",
                ]
            )
        )

        let freshness = HLSHTTPResponseFreshness(response: response)

        #expect(freshness.responseDate == nil)
        #expect(freshness.lastModified == nil)
        #expect(freshness.reportedAge == nil)
    }
}
