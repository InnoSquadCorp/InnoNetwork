import Foundation

package protocol CredentialExecutable: Sendable {
    var credentialExecution: RequestSecurityExecution? { get }
}

/// Owned by one executable, not by the reusable endpoint or client.
package actor RequestSecurityExecution {
    private let security: RequestSecurity
    private var selection: RequestSecurity.Selection?

    package init(_ security: RequestSecurity) { self.security = security }

    func prepare(for request: URLRequest) async throws -> PreparedRequestSecurity {
        guard let url = request.url, RequestSecurity.canonicalOrigin(url) == security.origin else {
            throw RequestSecurityFailure.originMismatch.networkError
        }
        try Task.checkCancellation()
        if selection == nil {
            let chosen: RequestSecurity.Selection
            do {
                chosen = try await security.provider.select(
                    alternatives: security.alternatives, origin: security.origin)
            } catch {
                if NetworkError.isCancellation(error) || Task.isCancelled { throw CancellationError() }
                throw RequestSecurityFailure.selectionFailed.networkError
            }
            try Task.checkCancellation()
            guard security.alternatives.indices.contains(chosen.alternative),
                RequestSecurity.validIdentifier(chosen.realm), RequestSecurity.validIdentifier(chosen.principal)
            else { throw RequestSecurityFailure.selectionFailed.networkError }
            selection = chosen
        }
        guard let selection else { throw RequestSecurityFailure.selectionFailed.networkError }
        return PreparedRequestSecurity(security: security, selection: selection)
    }
}

struct PreparedRequestSecurity: Sendable {
    let security: RequestSecurity
    let selection: RequestSecurity.Selection

    var schemes: [RequestSecurity.Scheme] { security.alternatives[selection.alternative] }

    var redaction: CredentialRedaction {
        var result = CredentialRedaction()
        for scheme in schemes {
            switch scheme {
            case .bearer: result.headers.insert("authorization")
            case .apiKey(_, let name, let location):
                switch location {
                case .header: result.headers.insert(name.lowercased())
                case .query: result.queryItems.insert(name)
                case .cookie: result.headers.formUnion(["cookie", "set-cookie"])
                }
            }
        }
        return result
    }

    func apply(to request: URLRequest) async throws -> URLRequest {
        guard let url = request.url, RequestSecurity.canonicalOrigin(url) == security.origin else {
            throw RequestSecurityFailure.originMismatch.networkError
        }
        guard
            ["Authorization", "Proxy-Authorization", "Cookie"].allSatisfy({
                request.value(forHTTPHeaderField: $0) == nil
            })
        else {
            throw RequestSecurityFailure.credentialConflict.networkError
        }
        // Check every slot before invoking a provider. Never partially send AND.
        for scheme in schemes { try checkVacant(scheme, request: request) }
        var credentials: [(RequestSecurity.Scheme, String)] = []
        for scheme in schemes {
            try Task.checkCancellation()
            let credential: RequestSecurity.Credential
            do {
                credential = try await security.provider.credential(
                    for: scheme, selection: selection, origin: security.origin)
            } catch {
                if NetworkError.isCancellation(error) || Task.isCancelled { throw CancellationError() }
                throw RequestSecurityFailure.credentialUnavailable.networkError
            }
            try Task.checkCancellation()
            guard credential.realm == selection.realm, credential.principal == selection.principal else {
                throw RequestSecurityFailure.identityChanged.networkError
            }
            guard validValue(credential.value, for: scheme) else {
                throw RequestSecurityFailure.credentialUnavailable.networkError
            }
            credentials.append((scheme, credential.value))
        }
        var result = request
        // Session cookie jars cannot silently supply a second principal.
        result.httpShouldHandleCookies = false
        for (scheme, value) in credentials {
            switch scheme {
            case .bearer: result.setValue("Bearer " + value, forHTTPHeaderField: "Authorization")
            case .apiKey(_, let name, let location):
                switch location {
                case .header: result.setValue(value, forHTTPHeaderField: name)
                case .query:
                    guard let current = result.url,
                        var parts = URLComponents(url: current, resolvingAgainstBaseURL: false)
                    else { throw RequestSecurityFailure.originMismatch.networkError }
                    parts.queryItems = (parts.queryItems ?? []) + [URLQueryItem(name: name, value: value)]
                    guard let updated = parts.url else { throw RequestSecurityFailure.invalidRequirements.networkError }
                    result.url = updated
                case .cookie:
                    let existing = result.value(forHTTPHeaderField: "Cookie")
                    result.setValue(
                        (existing.map { $0 + "; " } ?? "") + name + "=" + value, forHTTPHeaderField: "Cookie")
                }
            }
        }
        return result
    }

    private func checkVacant(_ scheme: RequestSecurity.Scheme, request: URLRequest) throws {
        let conflict: Bool
        switch scheme {
        case .bearer: conflict = request.value(forHTTPHeaderField: "Authorization") != nil
        case .apiKey(_, let name, let location):
            switch location {
            case .header: conflict = request.value(forHTTPHeaderField: name) != nil
            case .query:
                conflict =
                    request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?
                    .queryItems?.contains { $0.name == name } ?? false
            case .cookie:
                // Cookie parsing varies across origins; do not merge caller cookies.
                conflict = request.value(forHTTPHeaderField: "Cookie") != nil
            }
        }
        guard !conflict else { throw RequestSecurityFailure.credentialConflict.networkError }
    }

    private func validValue(_ value: String, for scheme: RequestSecurity.Scheme) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 8192,
            value.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
        else { return false }
        switch scheme {
        case .bearer:
            return value.utf8.allSatisfy { byte in
                (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte)
                    || "-._~+/=".utf8.contains(byte)
            }
        case .apiKey(_, _, .header): return value.utf8.allSatisfy { (32...126).contains($0) }
        case .apiKey(_, _, .cookie):
            return value.utf8.allSatisfy { (33...126).contains($0) && !"\";,\\".utf8.contains($0) }
        case .apiKey(_, _, .query): return true
        }
    }

    func validateAfterSigning(_ signed: URLRequest, authenticated: URLRequest) throws {
        // Signers may add a signature, never overwrite a provider's credential.
        guard signed.url == authenticated.url,
            redaction.headers.allSatisfy({
                signed.value(forHTTPHeaderField: $0) == authenticated.value(forHTTPHeaderField: $0)
            })
        else { throw RequestSecurityFailure.credentialConflict.networkError }
    }
}

/// Task-local metadata contains names only, never credential values.
package struct CredentialRedaction: Sendable {
    package var headers: Set<String> = []
    package var queryItems: Set<String> = []
    @TaskLocal package static var current: CredentialRedaction?

    func response(_ response: HTTPURLResponse) throws -> HTTPURLResponse {
        guard let url = response.url,
            var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { throw RequestSecurityFailure.originMismatch.networkError }
        parts.queryItems = parts.queryItems?.map {
            queryItems.contains($0.name) ? URLQueryItem(name: $0.name, value: "<redacted>") : $0
        }
        var fields: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            guard let name = key as? String else { continue }
            fields[name] = headers.contains(name.lowercased()) ? "<redacted>" : String(describing: value)
        }
        guard let sanitizedURL = parts.url,
            let sanitized = HTTPURLResponse(
                url: sanitizedURL, statusCode: response.statusCode, httpVersion: nil, headerFields: fields)
        else { throw RequestSecurityFailure.invalidRequirements.networkError }
        return sanitized
    }

    /// Retain retry classification, never arbitrary secret-bearing error text.
    static func failure(_ error: Error) -> NetworkError {
        let mapped = NetworkError.mapTransportError(error)
        func safe(_ error: SendableUnderlyingError) -> SendableUnderlyingError {
            SendableUnderlyingError(
                domain: error.domain, code: error.code, message: "Credential-protected transport failed.")
        }
        switch mapped {
        case .cancelled: return .cancelled
        case .timeout(let reason, let error): return .timeout(reason: reason, underlying: error.map(safe))
        case .reachability(let reason, let error, _): return .reachability(reason, safe(error), nil)
        case .underlying(let error, _): return .underlying(safe(error), nil)
        case .trustEvaluationFailed:
            return .trustEvaluationFailed(.custom("Credential-protected trust evaluation failed."))
        case .configuration:
            return .configuration(reason: .invalidRequest("Credential-protected transport configuration failed."))
        case .statusCode, .decoding: return RequestSecurityFailure.credentialUnavailable.networkError
        }
    }
}
