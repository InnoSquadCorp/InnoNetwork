import Foundation
import InnoNetwork

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

package struct HLSHTTPResponseFreshness: Equatable, Sendable {
    package let responseDate: Date?
    package let lastModified: Date?
    package let reportedAge: TimeInterval?

    package init(response: URLResponse) {
        guard let response = response as? HTTPURLResponse else {
            self.responseDate = nil
            self.lastModified = nil
            self.reportedAge = nil
            return
        }
        self.responseDate =
            response
            .value(forHTTPHeaderField: "Date")
            .flatMap {
                HTTPDateParser.parse($0, requiresGMTZone: true)
            }
        self.lastModified =
            response
            .value(forHTTPHeaderField: "Last-Modified")
            .flatMap {
                HTTPDateParser.parse($0, requiresGMTZone: true)
            }
        self.reportedAge = Self.parseAge(
            response.value(forHTTPHeaderField: "Age")
        )
    }

    private static func parseAge(
        _ value: String?
    ) -> TimeInterval? {
        guard
            let value = value?.trimmingCharacters(
                in: .whitespacesAndNewlines
            ),
            !value.isEmpty,
            value.allSatisfy({ $0.isASCII && $0.isNumber }),
            let seconds = TimeInterval(value),
            seconds.isFinite
        else {
            return nil
        }
        return seconds
    }
}
