import Foundation

/// Options used when rendering a `URLRequest` as a privacy-safe diagnostic curl command.
public struct CurlCommandOptions: Sendable, Equatable {
    /// Whether header values should be emitted. Header names remain visible
    /// by default while every value renders as `<redacted>`.
    public let includesHeaderValues: Bool
    /// Whether the rendered command should include a request body when known.
    public let includesBody: Bool
    /// Whether query values should be emitted. Query keys remain visible by
    /// default while their values render as `<redacted>`.
    public let includesQueryValues: Bool
    /// Optional file URL used when the body is file-backed or too large for inline output.
    public let bodyFileURL: URL?

    public init(
        includesHeaderValues: Bool = false,
        includesBody: Bool = false,
        includesQueryValues: Bool = false,
        bodyFileURL: URL? = nil
    ) {
        self.includesHeaderValues = includesHeaderValues
        self.includesBody = includesBody
        self.includesQueryValues = includesQueryValues
        self.bodyFileURL = bodyFileURL
    }
}

public extension URLRequest {
    /// Returns a shell-escaped diagnostic curl command for the request.
    ///
    /// Header and query values are redacted by default; URL user-info and
    /// fragments are always removed. Request bodies are omitted unless
    /// ``CurlCommandOptions/includesBody`` is explicitly enabled.
    /// Opted-in UTF-8 bodies use `--data-raw`; file-backed bodies use
    /// ``CurlCommandOptions/bodyFileURL``.
    func curlCommand(options: CurlCommandOptions = CurlCommandOptions()) -> String {
        let headerCount = allHTTPHeaderFields?.count ?? 0
        // Worst-case appends:  curl + method(2) + header(2 per header) +
        //                      body(2) + url(1). Slight overshoot is fine;
        //                      avoids the early geometric reallocations.
        var parts: [String] = []
        parts.reserveCapacity(4 + headerCount * 2 + 3)
        parts.append("curl")
        if let method = httpMethod, method != HTTPMethod.get.rawValue {
            parts.append("-X")
            parts.append(Self.shellEscape(method))
        }

        for (name, value) in (allHTTPHeaderFields ?? [:]).sorted(by: { $0.key.lowercased() < $1.key.lowercased() }) {
            let renderedValue = options.includesHeaderValues ? value : "<redacted>"
            parts.append("-H")
            parts.append(Self.shellEscape("\(name): \(renderedValue)"))
        }

        if options.includesBody {
            if let bodyFileURL = options.bodyFileURL {
                parts.append("--data-binary")
                parts.append(Self.shellEscape("@\(bodyFileURL.path)"))
            } else if let httpBody, !httpBody.isEmpty, let body = String(data: httpBody, encoding: .utf8) {
                parts.append("--data-raw")
                parts.append(Self.shellEscape(body))
            }
        }

        parts.append(
            Self.shellEscape(
                NetworkURLMetadataRedactor.string(
                    from: url,
                    includesQueryValues: options.includesQueryValues
                )
            )
        )
        return parts.joined(separator: " ")
    }

    private static func shellEscape(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}
