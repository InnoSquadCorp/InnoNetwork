import Foundation

/// Opt-in credential requirements for buffered and multipart endpoints.
///
/// Conform alongside `APIDefinition` or `MultipartAPIDefinition` and use
/// `sessionAuthentication = .anonymous`. Streaming and named encoded endpoints
/// do not yet support this contract and fail before sending. Encoded endpoints
/// reject it before their request factory runs. Existing session bearer auth is unchanged.
public protocol RequestSecurityProviding: Sendable {
    /// Origin-bound, non-secret requirements and the application-owned provider.
    var requestSecurity: RequestSecurity { get }
}

/// Supplies credentials without putting secrets in generated endpoint code.
///
/// Selection is frozen for one logical request, including retries. Providers
/// must honor cancellation and must not launch authentication UI implicitly.
/// Credential acquisition can run again on retry, but cannot change identity.
public protocol RequestCredentialProvider: Sendable {
    /// Explicitly selects an OR alternative and a non-secret identity partition.
    func select(alternatives: [[RequestSecurity.Scheme]], origin: URL) async throws -> RequestSecurity.Selection
    /// Obtains one credential for the already selected identity and origin.
    func credential(
        for scheme: RequestSecurity.Scheme, selection: RequestSecurity.Selection, origin: URL
    ) async throws -> RequestSecurity.Credential
}

/// Optional OAuth renewal, without login UI or permission escalation.
///
/// Persist the replacement in application-owned storage before returning. Core
/// shares overlapping renewals only within the same `RequestSecurity` value,
/// origin, scheme, exact requested scopes and selected realm/principal.
public protocol OAuthCredentialRefreshing: RequestCredentialProvider {
    /// Renews for the frozen identity and declared scopes, never server-suggested scopes.
    func refreshCredential(
        for scheme: RequestSecurity.Scheme, selection: RequestSecurity.Selection, origin: URL
    ) async throws -> RequestSecurity.Credential
}

/// Bounded AND/OR authentication metadata, with application-owned credentials.
///
/// Each inner array is AND; the provider explicitly selects one outer OR entry.
/// An empty inner array is an explicit anonymous alternative, never a fallback.
/// Requests bypass response caches/coalescing and all automatic redirects.
public struct RequestSecurity: Sendable {
    /// API-key wire placement. Query and cookie use require explicit opt-in.
    public enum Location: Sendable, Equatable {
        /// A single HTTP header.
        case header
        /// An exact, case-sensitive URL query parameter.
        case query
        /// An exact, case-sensitive cookie name.
        case cookie
    }

    /// One named credential requirement. Values contain no secrets.
    public enum Scheme: Sendable, Equatable {
        /// An OpenAPI API key, retaining its declared name and location.
        case apiKey(id: String, name: String, location: Location)
        /// An opaque bearer credential in Authorization.
        case bearer(id: String)
        /// OAuth bearer with exact, case-sensitive required scopes.
        case oauth2(id: String, scopes: [String])

        /// The specification's case-sensitive security scheme identifier.
        public var id: String {
            switch self {
            case .apiKey(let id, _, _), .bearer(let id), .oauth2(let id, _): return id
            }
        }
    }

    /// A non-secret principal selection pinned across all request attempts.
    public struct Selection: Sendable, Equatable {
        /// Index of the explicitly selected alternative.
        public let alternative: Int
        /// Application-owned non-secret realm identifier; never a token.
        public let realm: String
        /// Application-owned non-secret principal identifier; never a token.
        public let principal: String

        /// Creates a selection, validated before acquiring any credential.
        public init(alternative: Int, realm: String, principal: String) {
            self.alternative = alternative
            self.realm = realm
            self.principal = principal
        }
    }

    /// A secret value and its provider-attested identity. Never persisted by core.
    public struct Credential: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
        let value: String
        let realm: String
        let principal: String
        let grantedScopes: [String]?
        let expiresAt: Date?

        /// Creates an opaque credential. Identity must equal the frozen selection.
        /// OAuth additionally requires provider-attested granted scopes and a
        /// finite expiry; nil means unknown, not unrestricted or non-expiring.
        public init(
            value: String, realm: String, principal: String,
            grantedScopes: [String]? = nil, expiresAt: Date? = nil
        ) {
            self.value = value
            self.realm = realm
            self.principal = principal
            self.grantedScopes = grantedScopes
            self.expiresAt = expiresAt
        }

        /// Secret-safe description.
        public var description: String { "RequestSecurity.Credential(<redacted>)" }
        /// Secret-safe debug description.
        public var debugDescription: String { description }
    }

    let origin: URL
    let alternatives: [[Scheme]]
    let provider: any RequestCredentialProvider
    let oauthRefreshes = OAuthCredentialRefreshCoordinator()

    /// Creates a validated requirement bound to one HTTPS origin.
    ///
    /// The URL must contain no credentials, query, fragment or non-root path.
    /// Maximums: 32 alternatives, 16 schemes per alternative and 256-byte names.
    /// API-key headers cannot be routing, framing, cookie or hop-by-hop fields.
    /// Query/cookie keys keep their specified location; they are never rewritten
    /// as headers. Apps remain responsible for short-lived credential issuance.
    public init(
        origin: URL,
        alternatives: [[Scheme]],
        provider: any RequestCredentialProvider,
        allowsQueryCredentials: Bool = false,
        allowsCookieCredentials: Bool = false
    ) throws {
        guard let canonical = Self.canonicalOrigin(origin),
            origin.path.isEmpty || origin.path == "/",
            origin.query == nil, origin.fragment == nil,
            !alternatives.isEmpty, alternatives.count <= 32
        else { throw RequestSecurityFailure.invalidRequirements }
        for alternative in alternatives {
            guard alternative.count <= 16, Set(alternative.map(\.id)).count == alternative.count else {
                throw RequestSecurityFailure.invalidRequirements
            }
            var slots: Set<String> = []
            for scheme in alternative {
                guard Self.validIdentifier(scheme.id) else { throw RequestSecurityFailure.invalidRequirements }
                let slot: String
                switch scheme {
                case .bearer:
                    slot = "header:authorization"
                case .oauth2(_, let scopes):
                    guard scopes.count <= 64, scopes.allSatisfy(Self.validScope), Set(scopes).count == scopes.count
                    else {
                        throw RequestSecurityFailure.invalidRequirements
                    }
                    slot = "header:authorization"
                case .apiKey(_, let name, let location):
                    guard Self.validToken(name) else { throw RequestSecurityFailure.invalidRequirements }
                    switch location {
                    case .header:
                        guard !Self.forbiddenHeaders.contains(name.lowercased()) else {
                            throw RequestSecurityFailure.invalidRequirements
                        }
                        slot = "header:" + name.lowercased()
                    case .query:
                        guard allowsQueryCredentials else { throw RequestSecurityFailure.invalidRequirements }
                        slot = "query:" + name
                    case .cookie:
                        guard allowsCookieCredentials else { throw RequestSecurityFailure.invalidRequirements }
                        slot = "cookie:" + name
                    }
                }
                guard slots.insert(slot).inserted else { throw RequestSecurityFailure.invalidRequirements }
            }
        }
        self.origin = canonical
        self.alternatives = alternatives
        self.provider = provider
    }

    static let forbiddenHeaders: Set<String> = [
        "host", "content-length", "transfer-encoding", "connection", "proxy-authorization",
        "proxy-authenticate", "cookie", "set-cookie", "trailer", "te", "upgrade", "keep-alive",
        "cache-control", "content-type", "accept-encoding", "idempotency-key",
    ]

    static func canonicalOrigin(_ url: URL) -> URL? {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
            parts.scheme?.lowercased() == "https", let host = parts.host, !host.isEmpty,
            parts.user == nil, parts.password == nil,
            parts.port.map({ (1...65535).contains($0) }) ?? true
        else { return nil }
        var result = URLComponents()
        result.scheme = "https"
        result.host = host.lowercased()
        result.port = parts.port == 443 ? nil : parts.port
        return result.url
    }

    static func validIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 256
            && value.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
    }

    static func validToken(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 256
            && value.utf8.allSatisfy { byte in
                (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte)
                    || "!#$%&'*+-.^_`|~".utf8.contains(byte)
            }
    }

    static func validScope(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 256
            && value.utf8.allSatisfy {
                $0 == 0x21 || (0x23...0x5B).contains($0) || (0x5D...0x7E).contains($0)
            }
    }
}

/// Secret-free failures at the opt-in request credential boundary.
///
/// Constructors throw this error directly. Execution wraps it in
/// `NetworkError.underlying` with domain `InnoNetwork.RequestSecurity` and this
/// raw code. Provider error descriptions are intentionally discarded.
public enum RequestSecurityFailure: Int, Error, Sendable {
    /// Invalid, conflicting, unsupported or over-budget metadata.
    case invalidRequirements = 1
    /// The final request does not target the bound HTTPS origin.
    case originMismatch
    /// The provider failed or did not select a declared alternative.
    case selectionFailed
    /// A provider failed to supply a valid credential.
    case credentialUnavailable
    /// Credential identity differs from the frozen selection.
    case identityChanged
    /// A credential would replace an existing header/query/cookie value.
    case credentialConflict
    /// Legacy auth or an unsupported execution surface conflicts with this contract.
    case unsupportedExecution
    /// OAuth requires provider-attested scopes and a finite expiry date.
    case scopeMetadataUnavailable
    /// The attested scope set does not cover the declared requirement.
    case insufficientScope
    /// The token has expired and cannot be renewed within this logical request.
    case credentialExpired
    /// Renewal failed, exceeded its concurrency bound or returned invalid metadata.
    case refreshFailed

    var networkError: NetworkError {
        .underlying(
            SendableUnderlyingError(
                domain: "InnoNetwork.RequestSecurity", code: rawValue,
                message: "Request credential boundary failed (\(rawValue))."
            ), nil
        )
    }
}
