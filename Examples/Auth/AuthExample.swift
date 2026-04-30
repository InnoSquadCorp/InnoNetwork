//
//  AuthExample.swift
//  InnoNetwork Examples
//
//  Demonstrates how to wire `RefreshTokenPolicy` to a Keychain-backed
//  token store. The Keychain wrapper here is reference-quality only —
//  production apps should layer access groups, biometric protection,
//  and multi-account scoping on top. The point is that the library
//  itself stays zero-dependency: storage is the application's
//  decision, RefreshTokenPolicy only owns single-flight refresh and
//  one-time replay after auth-class status codes.
//

import Foundation
import InnoNetwork
import Security

// MARK: - 1. Keychain wrapper

/// Minimal `SecItem` wrapper kept inside an actor so concurrent
/// reads/writes serialize. Stores a single item per `account` under
/// the supplied `service` identifier.
actor KeychainTokenStore {
    enum KeychainError: Error {
        case unexpectedStatus(OSStatus)
    }

    private let service: String
    private let account: String

    init(service: String, account: String) {
        self.service = service
        self.account = account
    }

    func read() throws -> String? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data, let token = String(data: data, encoding: .utf8) else {
                return nil
            }
            return token
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    func write(_ token: String) throws {
        let data = Data(token.utf8)

        // Try to update first; if no item exists, fall through to add.
        let updateAttributes: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(baseQuery() as CFDictionary, updateAttributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        if updateStatus != errSecItemNotFound {
            throw KeychainError.unexpectedStatus(updateStatus)
        }

        var addQuery = baseQuery()
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainError.unexpectedStatus(addStatus)
        }
    }

    func delete() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

// MARK: - 2. Auth service that exposes the closures RefreshTokenPolicy needs

/// Thin coordinator that talks to the auth backend. The closures
/// passed to `RefreshTokenPolicy` close over an instance of this
/// actor so the policy stays decoupled from the storage layer.
actor AuthService {
    private let store: KeychainTokenStore
    private let refreshURL: URL
    private let session: URLSession

    init(store: KeychainTokenStore, refreshURL: URL, session: URLSession = .shared) {
        self.store = store
        self.refreshURL = refreshURL
        self.session = session
    }

    func currentAccessToken() async throws -> String? {
        try await store.read()
    }

    /// Production servers usually require a refresh token, signing
    /// nonce, or device id here. This example posts an opaque marker
    /// to keep the wire shape obvious.
    func refreshAccessToken() async throws -> String {
        var request = URLRequest(url: refreshURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.userAuthenticationRequired)
        }
        struct RefreshResponse: Decodable { let accessToken: String }
        let decoded = try JSONDecoder().decode(RefreshResponse.self, from: data)
        try await store.write(decoded.accessToken)
        return decoded.accessToken
    }
}

// MARK: - 3. Wire RefreshTokenPolicy to the auth service

/// Builds a `NetworkConfiguration` with a Keychain-backed
/// `RefreshTokenPolicy`. The policy fires its single-flight refresh
/// when the server responds with `401`; other status codes flow
/// through unchanged. `applyToken` defaults to a Bearer
/// `Authorization` header — override only when the API expects a
/// custom scheme.
func makeAuthenticatedConfiguration(baseURL: URL) -> NetworkConfiguration {
    let store = KeychainTokenStore(service: "com.example.app", account: "primary")
    let auth = AuthService(
        store: store,
        refreshURL: baseURL.appendingPathComponent("/auth/refresh")
    )

    let policy = RefreshTokenPolicy(
        refreshStatusCodes: [401],
        currentToken: { try await auth.currentAccessToken() },
        refreshToken: { try await auth.refreshAccessToken() }
    )

    return NetworkConfiguration.advanced(baseURL: baseURL) { builder in
        builder.refreshTokenPolicy = policy
    }
}

// MARK: - 4. Use the configured client

struct Profile: Decodable, Sendable {
    let id: Int
    let name: String
}

struct GetProfile: APIDefinition {
    typealias Parameter = EmptyParameter
    typealias APIResponse = Profile

    var method: HTTPMethod { .get }
    var path: String { "/me" }
}

@main
struct AuthExampleApp {
    static func main() async {
        let baseURL = URL(string: "https://api.example.com/v1")!
        let configuration = makeAuthenticatedConfiguration(baseURL: baseURL)
        let client = DefaultNetworkClient(configuration: configuration)

        do {
            let profile = try await client.request(GetProfile())
            print("✅ Fetched profile: \(profile)")
        } catch {
            // A 401 will trigger one refresh + replay automatically.
            // A second 401 after replay surfaces the real error here.
            print("❌ Request failed: \(error)")
        }
    }
}
