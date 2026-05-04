import Foundation

/// Options used when rendering a `URLRequest` as a reproducible curl command.
public struct CurlCommandOptions: Sendable, Equatable {
    public static let defaultRedactedHeaderNames: Set<String> = [
        "authorization",
        "cookie",
        "idempotency-key",
        "proxy-authorization",
        "set-cookie",
    ]

    public let redactedHeaderNames: Set<String>
    public let includesBody: Bool
    public let bodyFileURL: URL?

    public init(
        redactedHeaderNames: Set<String> = Self.defaultRedactedHeaderNames,
        includesBody: Bool = true,
        bodyFileURL: URL? = nil
    ) {
        self.redactedHeaderNames = Set(redactedHeaderNames.map { $0.lowercased() })
        self.includesBody = includesBody
        self.bodyFileURL = bodyFileURL
    }
}

public extension URLRequest {
    /// Returns a shell-escaped curl command that reproduces the request.
    ///
    /// Sensitive headers are redacted by default. In-memory UTF-8 bodies are
    /// emitted with `--data-raw`; file-backed bodies can be represented by
    /// passing ``CurlCommandOptions/bodyFileURL``.
    func curlCommand(options: CurlCommandOptions = CurlCommandOptions()) -> String {
        var parts = ["curl"]
        if let method = httpMethod, method.uppercased() != "GET" {
            parts.append("-X")
            parts.append(Self.shellEscape(method.uppercased()))
        }

        for (name, value) in (allHTTPHeaderFields ?? [:]).sorted(by: { $0.key.lowercased() < $1.key.lowercased() }) {
            let renderedValue =
                options.redactedHeaderNames.contains(name.lowercased()) ? "<redacted>" : value
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

        parts.append(Self.shellEscape(url?.absoluteString ?? ""))
        return parts.joined(separator: " ")
    }

    private static func shellEscape(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}
