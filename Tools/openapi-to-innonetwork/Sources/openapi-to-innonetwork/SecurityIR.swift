import Foundation

/// Non-secret generation IR. Array entries are OR; members of an entry are AND.
/// This is deliberately not a token/login model and does not select a preferred
/// alternative. Empty requirements and an explicit anonymous alternative remain
/// distinguishable until rendering.
struct SecurityIR: Equatable {
    struct Requirement: Equatable {
        enum Kind: Equatable {
            case bearer
            case apiKey(name: String, location: Location)
            case oauth2
        }

        enum Location: String {
            case header, query, cookie
        }

        let schemeID: String
        let kind: Kind
        let scopes: [String]

        var wireSlot: String {
            switch kind {
            case .bearer, .oauth2: "header:authorization"
            case .apiKey(let name, let location):
                "\(location.rawValue):\(location == .header ? name.lowercased() : name)"
            }
        }
    }

    let alternatives: [[Requirement]]

    init(requirements: [[String: [String]]]?, schemes: [String: SecurityScheme]) throws {
        let requirements = requirements ?? []
        guard requirements.count <= 32 else {
            throw GenerationError.unsupportedSecurity("Security alternatives exceed the 32-alternative limit")
        }
        alternatives = try requirements.map { alternative in
            guard alternative.count <= 16 else {
                throw GenerationError.unsupportedSecurity("Security AND requirements exceed the 16-scheme limit")
            }
            var slots: Set<String> = []
            return try alternative.keys.sorted().map { id in
                guard Self.validIdentifier(id), let scheme = schemes[id], let scopes = alternative[id],
                    scopes.count <= 64, scopes.allSatisfy(Self.validScope), Set(scopes).count == scopes.count
                else {
                    throw GenerationError.unsupportedSecurity("Unknown scheme or invalid security requirement")
                }
                let kind: Requirement.Kind
                switch scheme.type {
                case "http":
                    guard scheme.scheme?.lowercased() == "bearer", scopes.isEmpty else {
                        throw GenerationError.unsupportedSecurity(
                            "HTTP security supports bearer with empty scopes only")
                    }
                    kind = .bearer
                case "apiKey":
                    guard scopes.isEmpty, let name = scheme.name,
                        let location = scheme.in.flatMap(Requirement.Location.init(rawValue:)),
                        Self.validWireName(name, location: location)
                    else {
                        throw GenerationError.unsupportedSecurity("Invalid API key name, location or scopes")
                    }
                    kind = .apiKey(name: name, location: location)
                case "oauth2":
                    let declared = try Self.declaredScopes(in: scheme.flows)
                    guard Set(scopes).isSubset(of: declared) else {
                        throw GenerationError.unsupportedSecurity("OAuth requirement contains an undeclared scope")
                    }
                    kind = .oauth2
                default:
                    throw GenerationError.unsupportedSecurity("Unsupported security scheme type")
                }
                let requirement = Requirement(schemeID: id, kind: kind, scopes: scopes.sorted())
                guard slots.insert(requirement.wireSlot).inserted else {
                    throw GenerationError.unsupportedSecurity("AND security schemes share a credential location")
                }
                // A Cookie header scheme would replace the assembled cookie list.
                if slots.contains("header:cookie"), slots.contains(where: { $0.hasPrefix("cookie:") }) {
                    throw GenerationError.unsupportedSecurity("Cookie header and cookie API keys cannot be combined")
                }
                return requirement
            }
        }
    }

    /// Legacy rendering is intentionally narrow until the dedicated provider
    /// pipeline is wired. In particular, different bearer schemes must not be
    /// collapsed into one session identity.
    func legacySessionAuthentication() throws -> String {
        var bearerIDs: Set<String> = []
        var anonymous = alternatives.isEmpty
        for alternative in alternatives {
            if alternative.isEmpty {
                anonymous = true
            } else if alternative.count == 1, let requirement = alternative.first, requirement.kind == .bearer {
                bearerIDs.insert(requirement.schemeID)
            } else {
                throw GenerationError.unsupportedSecurity(
                    "This security contract requires the dedicated credential-provider adapter")
            }
        }
        guard bearerIDs.count <= 1 else {
            throw GenerationError.unsupportedSecurity(
                "Distinct bearer alternatives require explicit application selection")
        }
        return bearerIDs.isEmpty ? "anonymous" : (anonymous ? "optional" : "required")
    }

    /// Provider-backed rendering retains every scheme identity and alternative.
    /// OAuth remains closed until the scoped refresh runtime is available.
    func runtimeAlternativesLiteral() throws -> String {
        func literal(_ value: String) -> String {
            // JSON string escaping is also valid Swift except interpolations.
            let escaped = value.unicodeScalars.map { scalar -> String in
                switch scalar.value {
                case 0x22: return "\\\""
                case 0x5C: return "\\\\"
                default: return String(scalar)
                }
            }.joined()
            return "\"" + escaped + "\""
        }
        return "["
            + (try alternatives.map { alternative in
                "["
                    + (try alternative.map { requirement in
                        switch requirement.kind {
                        case .bearer: return ".bearer(id: \(literal(requirement.schemeID)))"
                        case .apiKey(let name, let location):
                            return
                                ".apiKey(id: \(literal(requirement.schemeID)), name: \(literal(name)), location: .\(location.rawValue))"
                        case .oauth2:
                            throw GenerationError.unsupportedSecurity(
                                "OAuth requires the scoped credential-provider adapter")
                        }
                    }).joined(separator: ", ") + "]"
            }).joined(separator: ", ") + "]"
    }

    private static func declaredScopes(in flows: [String: OAuthFlow]?) throws -> Set<String> {
        guard let flows, !flows.isEmpty, flows.count <= 4 else {
            throw GenerationError.unsupportedSecurity("OAuth requires a declared flow")
        }
        var scopes: Set<String> = []
        for (name, flow) in flows {
            let needsAuthorization = name == "implicit" || name == "authorizationCode"
            let needsToken = name == "password" || name == "clientCredentials" || name == "authorizationCode"
            guard needsAuthorization || needsToken,
                !needsAuthorization || validHTTPSURL(flow.authorizationUrl),
                !needsToken || validHTTPSURL(flow.tokenUrl),
                flow.refreshUrl == nil || validHTTPSURL(flow.refreshUrl),
                flow.scopes.count <= 256, flow.scopes.keys.allSatisfy(validScope)
            else {
                throw GenerationError.unsupportedSecurity("Unsupported or invalid OAuth flow metadata")
            }
            scopes.formUnion(flow.scopes.keys)
        }
        return scopes
    }

    private static func validHTTPSURL(_ value: String?) -> Bool {
        guard let value, let url = URLComponents(string: value) else { return false }
        return url.scheme?.lowercased() == "https" && !(url.host ?? "").isEmpty
            && url.user == nil && url.password == nil && url.fragment == nil
    }

    private static func validIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 256
            && value.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
    }

    private static func validScope(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 256
            && value.utf8.allSatisfy {
                $0 == 0x21 || (0x23...0x5B).contains($0) || (0x5D...0x7E).contains($0)
            }
    }

    private static func validWireName(_ value: String, location: Requirement.Location) -> Bool {
        guard validIdentifier(value) else { return false }
        let token = CharacterSet(
            charactersIn: "!#$%&'*+-.^_`|~0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")
        guard value.unicodeScalars.allSatisfy(token.contains) else { return false }
        if location == .header {
            return ![
                "host", "content-length", "transfer-encoding", "connection", "proxy-authorization",
                "proxy-authenticate", "cookie", "set-cookie", "trailer", "te", "upgrade", "keep-alive",
                "cache-control", "content-type", "accept-encoding", "idempotency-key",
            ].contains(
                value.lowercased())
        }
        return true
    }
}
