import Foundation

/// Coarse request priority hint mapped onto `URLRequest.networkServiceType`.
public enum RequestPriority: Sendable, Equatable {
    /// Background transfer or refresh work.
    case background
    /// Default priority for normal user-visible requests.
    case normal
    /// Latency-sensitive user-initiated work.
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
