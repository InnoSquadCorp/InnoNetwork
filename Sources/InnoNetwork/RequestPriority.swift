import Foundation

/// Coarse request priority hint mapped onto `URLRequest.networkServiceType`.
public enum RequestPriority: Sendable, Equatable {
    case background
    case normal
    case userInitiated

    package var networkServiceType: URLRequest.NetworkServiceType {
        switch self {
        case .background:
            return .background
        case .normal:
            return .default
        case .userInitiated:
            return .responsiveData
        }
    }
}
