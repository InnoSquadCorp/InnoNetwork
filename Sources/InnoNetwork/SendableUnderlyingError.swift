import Foundation

public struct SendableUnderlyingError: Error, Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    /// Single frame in an `NSUnderlyingErrorKey` chain. Flat so the
    /// surrounding struct can store an array without falling into
    /// recursive value-type storage.
    public struct Frame: Sendable, Equatable, CustomStringConvertible {
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

        public var description: String { "\(domain)(\(code)): \(message)" }
    }

    public let domain: String
    public let code: Int
    public let message: String
    public let failureReason: String?
    public let recoverySuggestion: String?
    /// Frames captured from `NSUnderlyingErrorKey`, ordered from the
    /// closest underlying cause outward. Empty when the source `NSError`
    /// had no chain. Bounded by ``maxUnderlyingDepth`` to keep
    /// pathological circular wraps from blowing up.
    public let underlyingChain: [Frame]

    /// Maximum number of `NSUnderlyingErrorKey` frames that
    /// ``init(_:)`` walks. Five frames is enough to capture the
    /// transport → POSIX → kernel chain typical of CFNetwork errors
    /// without unbounded recursion when an upstream introduces a cycle.
    public static let maxUnderlyingDepth: Int = 5

    public init(
        domain: String,
        code: Int,
        message: String,
        failureReason: String? = nil,
        recoverySuggestion: String? = nil,
        underlyingChain: [Frame] = []
    ) {
        self.domain = domain
        self.code = code
        self.message = message
        self.failureReason = failureReason
        self.recoverySuggestion = recoverySuggestion
        self.underlyingChain = underlyingChain
    }

    public init(_ error: Error) {
        let nsError = error as NSError
        self.domain = nsError.domain
        self.code = nsError.code
        self.message = nsError.localizedDescription
        self.failureReason = nsError.localizedFailureReason
        self.recoverySuggestion = nsError.localizedRecoverySuggestion
        self.underlyingChain = Self.captureChain(from: nsError)
    }

    /// First frame of the underlying chain, when the source error wrapped
    /// a cause via `NSUnderlyingErrorKey`.
    public var underlying: Frame? { underlyingChain.first }

    private static func captureChain(from error: NSError) -> [Frame] {
        var frames: [Frame] = []
        var cursor: NSError? = error.userInfo[NSUnderlyingErrorKey] as? NSError
        while let current = cursor, frames.count < maxUnderlyingDepth - 1 {
            frames.append(
                Frame(
                    domain: current.domain,
                    code: current.code,
                    message: current.localizedDescription,
                    failureReason: current.localizedFailureReason,
                    recoverySuggestion: current.localizedRecoverySuggestion
                )
            )
            cursor = current.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return frames
    }

    public var description: String {
        var output = "\(domain)(\(code)): \(message)"
        for frame in underlyingChain {
            output += " ← \(frame)"
        }
        return output
    }

    public var debugDescription: String {
        var output = "SendableUnderlyingError(domain: \(domain), code: \(code), message: \(message)"
        if let failureReason { output += ", failureReason: \(failureReason)" }
        if let recoverySuggestion { output += ", recoverySuggestion: \(recoverySuggestion)" }
        if !underlyingChain.isEmpty {
            output += ", underlyingChain: \(underlyingChain)"
        }
        output += ")"
        return output
    }
}
