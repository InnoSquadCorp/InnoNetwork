import Foundation

package enum NetworkErrorCategory: Sendable, Equatable {
    case configuration
    case statusCode
    case decoding
    case transport
    case reachability
    case trust
    case cancellation
    case timeout
}

extension NetworkError {
    package var category: NetworkErrorCategory {
        switch self {
        case .configuration:
            return .configuration
        case .statusCode:
            return .statusCode
        case .decoding:
            return .decoding
        case .underlying:
            return .transport
        case .reachability:
            return .reachability
        case .trustEvaluationFailed:
            return .trust
        case .cancelled:
            return .cancellation
        case .timeout:
            return .timeout
        }
    }

    package var isRetriableHint: Bool {
        switch self {
        case .statusCode(let response):
            response.statusCode == 408
                || response.statusCode == 429
                || (500...599).contains(response.statusCode)
        case .underlying(let error, _):
            !Self.isCancellation(error)
        case .reachability, .timeout:
            true
        case .configuration, .decoding, .trustEvaluationFailed, .cancelled:
            false
        }
    }

    package var isUserVisible: Bool {
        switch self {
        case .configuration(reason: .offline):
            return true
        case .configuration(reason: .invalidBaseURL),
            .configuration(reason: .invalidRequest),
            .cancelled:
            return false
        case .statusCode,
            .decoding,
            .underlying,
            .reachability,
            .trustEvaluationFailed,
            .timeout:
            return true
        }
    }
}
