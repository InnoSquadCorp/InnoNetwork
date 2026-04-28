import Foundation

public struct SendableUnderlyingError: Error, Sendable, Equatable, CustomStringConvertible {
    public let domain: String
    public let code: Int
    public let message: String
    public let failureReason: String?
    public let recoverySuggestion: String?

    public init(
        domain: String,
        code: Int,
        message: String,
        failureReason: String? = nil,
        recoverySuggestion: String? = nil
    ) {
        self.domain = domain
        self.code = code
        self.message = message
        self.failureReason = failureReason
        self.recoverySuggestion = recoverySuggestion
    }

    public init(_ error: Error) {
        let nsError = error as NSError
        self.domain = nsError.domain
        self.code = nsError.code
        self.message = nsError.localizedDescription
        self.failureReason = nsError.localizedFailureReason
        self.recoverySuggestion = nsError.localizedRecoverySuggestion
    }

    public var description: String {
        "\(domain)(\(code)): \(message)"
    }
}
