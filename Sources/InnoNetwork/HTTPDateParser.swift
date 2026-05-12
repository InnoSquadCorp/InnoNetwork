import Foundation
import os

/// Shared parser for RFC 9110 HTTP-date values.
package enum HTTPDateParser {
    private static let dateFormats = [
        "EEE, dd MMM yyyy HH:mm:ss zzz",  // IMF-fixdate
        "EEEE, dd-MMM-yy HH:mm:ss zzz",  // RFC 850
        "EEE MMM  d HH:mm:ss yyyy",  // asctime single-digit day (two spaces)
        "EEE MMM d HH:mm:ss yyyy",  // asctime (no zone; formatter.timeZone applies)
    ]

    private static let formatter = OSAllocatedUnfairLock<DateFormatter>(
        initialState: {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            return formatter
        }()
    )

    package static func parse(_ value: String, requiresGMTZone: Bool = false) -> Date? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let candidates = parseCandidates(for: trimmed)

        for candidate in candidates {
            guard !requiresGMTZone || hasGMTZoneOrNoZone(candidate) else { continue }
            if let date = parseCandidate(candidate) {
                return date
            }
        }
        return nil
    }

    private static func parseCandidates(for trimmed: String) -> [String] {
        let normalizedWhitespace =
            trimmed
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .joined(separator: " ")
        guard normalizedWhitespace != trimmed else { return [trimmed] }
        // RFC asctime uses two spaces before a one-digit day. Preserve that
        // exact candidate before trying the compatibility-normalized form so
        // `Sun Nov  6 ...` is not accepted only as a side effect of whitespace
        // folding.
        return [trimmed, normalizedWhitespace]
    }

    private static func parseCandidate(_ value: String) -> Date? {
        formatter.withLock { formatter in
            for format in dateFormats {
                formatter.dateFormat = format
                if let date = formatter.date(from: value) {
                    return date
                }
            }
            return nil
        }
    }

    private static func hasGMTZoneOrNoZone(_ value: String) -> Bool {
        // The two comma-bearing HTTP-date forms carry a zone token; RFC 9111
        // cache freshness calculations should reject zone abbreviations other
        // than GMT. The asctime form has no zone token and is interpreted as
        // GMT by the formatter above.
        guard value.contains(",") else { return true }
        guard let zone = value.split(separator: " ").last else { return false }
        return zone.caseInsensitiveCompare("GMT") == .orderedSame
    }
}
