import Foundation

/// Policy that attaches a stable idempotency key to one logical request.
///
/// Unlike a plain ``RequestInterceptor``, this policy is evaluated with the
/// retry loop's stable request id. Every retry attempt for the same logical
/// request therefore reuses the same header value.
public struct IdempotencyKeyPolicy: Sendable {
    public let headerName: String
    public let methods: Set<HTTPMethod>
    public let keyProvider: @Sendable (UUID) -> String?

    public static let disabled = IdempotencyKeyPolicy(methods: []) { _ in nil }

    public static func automaticForUnsafeMethods(
        headerName: String = "Idempotency-Key",
        keyProvider: @escaping @Sendable (UUID) -> String = { $0.uuidString }
    ) -> IdempotencyKeyPolicy {
        IdempotencyKeyPolicy(
            headerName: headerName,
            methods: [.post, .put, .patch, .delete],
            keyProvider: keyProvider
        )
    }

    public init(
        headerName: String = "Idempotency-Key",
        methods: Set<HTTPMethod>,
        keyProvider: @escaping @Sendable (UUID) -> String?
    ) {
        self.headerName = headerName
        self.methods = methods
        self.keyProvider = keyProvider
    }

    package func apply(to request: inout URLRequest, requestID: UUID) {
        guard let method = HTTPMethod(rawValue: (request.httpMethod ?? "GET").uppercased()),
            methods.contains(method),
            request.value(forHTTPHeaderField: headerName)?.isEmpty != false,
            let key = keyProvider(requestID),
            !key.isEmpty
        else {
            return
        }
        request.setValue(key, forHTTPHeaderField: headerName)
    }
}
