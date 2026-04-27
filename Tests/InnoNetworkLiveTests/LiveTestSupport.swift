import Foundation
import Testing

/// Returns true when the live-endpoint test suite has been opted into via
/// `INNO_LIVE=1`. Defaults to false so a regular `swift test` run completes
/// quickly without making outbound network requests.
func liveTestsEnabled() -> Bool {
    let value = ProcessInfo.processInfo.environment["INNO_LIVE"] ?? ""
    return value == "1" || value.lowercased() == "true"
}

/// Trait applied to live-endpoint tests so they are skipped (not failed)
/// unless `INNO_LIVE=1` is set in the environment. Use as
/// `@Test("name", .liveOnly)`.
extension Trait where Self == ConditionTrait {
    static var liveOnly: ConditionTrait {
        .enabled(
            if: liveTestsEnabled(),
            "INNO_LIVE not set; skipping live-endpoint test. Run with INNO_LIVE=1 swift test."
        )
    }
}
