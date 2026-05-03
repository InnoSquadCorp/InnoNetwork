import Foundation

/// Splits an HTTP list-rule header value into its top-level elements,
/// honoring RFC 9110 §5.6 quoted-string content. Commas appearing inside
/// a quoted-string (`"…,…"`) do **not** terminate an element; quoted-pair
/// escape sequences (`\"`, `\\`) inside a quoted-string are preserved.
///
/// This is needed for headers like `Cache-Control: private="X-Foo, X-Bar"`
/// where a naive `split(separator: ",")` would shred the quoted directive
/// into invalid pieces and silently corrupt cache directives.
package enum HTTPListParser {
    /// Splits `value` at top-level commas, returning each element verbatim
    /// (quoted-string contents preserved, surrounding whitespace trimmed).
    /// Empty elements (consecutive commas) are dropped.
    package static func split(_ value: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var inQuotes = false
        var iterator = value.makeIterator()

        while let scalar = iterator.next() {
            if inQuotes {
                if scalar == "\\" {
                    current.append(scalar)
                    if let next = iterator.next() { current.append(next) }
                    continue
                }
                if scalar == "\"" {
                    current.append(scalar)
                    inQuotes = false
                    continue
                }
                current.append(scalar)
                continue
            }

            if scalar == "\"" {
                current.append(scalar)
                inQuotes = true
                continue
            }
            if scalar == "," {
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { parts.append(trimmed) }
                current = ""
                continue
            }
            current.append(scalar)
        }

        let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { parts.append(trimmed) }
        return parts
    }

    /// Returns the lowercased directive *name* portion of a single
    /// Cache-Control element (everything before `=`, trimmed). Element
    /// values, including quoted-string contents like
    /// `private="X-Foo, X-Bar"`, are discarded — this helper is for
    /// presence checks only.
    package static func directiveName(of element: String) -> String {
        let firstEquals = element.firstIndex(of: "=")
        let name = firstEquals.map { String(element[..<$0]) } ?? element
        return name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
