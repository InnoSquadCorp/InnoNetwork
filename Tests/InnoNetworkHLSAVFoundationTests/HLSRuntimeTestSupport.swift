import Foundation
import Testing

extension Trait where Self == ConditionTrait {
    static func hlsRuntimeURL(
        _ environmentKey: String
    ) -> ConditionTrait {
        .enabled(
            if: ProcessInfo.processInfo.environment[environmentKey]
                .flatMap(URL.init(string:)) != nil,
            "\(environmentKey) does not provide a valid runtime URL"
        )
    }
}

func hlsRuntimeURL(environmentKey: String) throws -> URL {
    let rawURL = try #require(
        ProcessInfo.processInfo.environment[environmentKey]
    )
    return try #require(URL(string: rawURL))
}
