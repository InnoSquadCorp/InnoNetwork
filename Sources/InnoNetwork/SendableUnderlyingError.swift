import Foundation

public struct SendableUnderlyingError: Error, Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible
{
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

        public static func == (lhs: Frame, rhs: Frame) -> Bool {
            lhs.domain == rhs.domain && lhs.code == rhs.code
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
        if let snapshot = error as? Self {
            self.init(
                domain: snapshot.domain, code: snapshot.code, message: snapshot.message,
                failureReason: snapshot.failureReason, recoverySuggestion: snapshot.recoverySuggestion,
                underlyingChain: Array(snapshot.underlyingChain.prefix(Self.maxUnderlyingDepth)))
            return
        }
        let nsError = error as NSError
        self.init(
            domain: nsError.domain, code: nsError.code, message: nsError.localizedDescription,
            failureReason: nsError.localizedFailureReason, recoverySuggestion: nsError.localizedRecoverySuggestion,
            underlyingChain: Self.captureChain(from: nsError))
    }

    public static func == (lhs: SendableUnderlyingError, rhs: SendableUnderlyingError) -> Bool {
        lhs.domain == rhs.domain && lhs.code == rhs.code
    }

    /// First frame of the underlying chain, when the source error wrapped
    /// a cause via `NSUnderlyingErrorKey`.
    public var underlying: Frame? { underlyingChain.first }

    private static func captureChain(from error: NSError) -> [Frame] {
        var frames: [Frame] = []
        var cursor: Any? = error.userInfo[NSUnderlyingErrorKey]
        while let cause = cursor, frames.count < maxUnderlyingDepth {
            // A value snapshot bridges to a generic Swift NSError, losing its
            // original domain and flattened causes. Read it before bridging.
            if let snapshot = cause as? Self {
                frames.append(
                    Frame(
                        domain: snapshot.domain, code: snapshot.code, message: snapshot.message,
                        failureReason: snapshot.failureReason, recoverySuggestion: snapshot.recoverySuggestion))
                frames.append(contentsOf: snapshot.underlyingChain.prefix(maxUnderlyingDepth - frames.count))
                break
            }
            guard let current = cause as? NSError else { break }
            frames.append(
                Frame(
                    domain: current.domain,
                    code: current.code,
                    message: current.localizedDescription,
                    failureReason: current.localizedFailureReason,
                    recoverySuggestion: current.localizedRecoverySuggestion
                )
            )
            cursor = current.userInfo[NSUnderlyingErrorKey]
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
