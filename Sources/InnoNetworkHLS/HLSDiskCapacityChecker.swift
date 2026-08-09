import Foundation

struct HLSDiskCapacityChecker: Sendable {
    private let capacityProvider: @Sendable (URL) throws -> Int64?

    init(
        capacityProvider:
            @escaping @Sendable (URL) throws -> Int64? = { directoryURL in
                #if os(watchOS) || os(tvOS)
                let values = try directoryURL.resourceValues(
                    forKeys: [.volumeAvailableCapacityKey]
                )
                return values.volumeAvailableCapacity.map(Int64.init)
                #else
                let values = try directoryURL.resourceValues(
                    forKeys: [
                        .volumeAvailableCapacityForImportantUsageKey,
                        .volumeAvailableCapacityKey,
                    ]
                )
                if let importantCapacity =
                    values.volumeAvailableCapacityForImportantUsage
                {
                    return importantCapacity
                }
                return values.volumeAvailableCapacity.map(Int64.init)
                #endif
            }
    ) {
        self.capacityProvider = capacityProvider
    }

    func validate(
        directoryURL: URL,
        policy: HLSDiskCapacityPolicy,
        additionalRequiredCapacity: Int64 = 0
    ) throws {
        guard
            let minimumAvailableCapacity =
                policy.normalizedMinimumAvailableCapacity
        else {
            return
        }

        let availableCapacity: Int64?
        do {
            availableCapacity = try capacityProvider(directoryURL)
        } catch {
            guard policy.requiresCapacityValue else {
                return
            }
            throw HLSDownloadError.diskCapacityUnavailable
        }

        guard let availableCapacity else {
            guard policy.requiresCapacityValue else {
                return
            }
            throw HLSDownloadError.diskCapacityUnavailable
        }

        let additionalCapacity = max(0, additionalRequiredCapacity)
        let (requiredCapacity, overflow) =
            minimumAvailableCapacity.addingReportingOverflow(
                additionalCapacity
            )
        let normalizedRequiredCapacity =
            overflow ? Int64.max : requiredCapacity
        guard availableCapacity >= normalizedRequiredCapacity else {
            throw HLSDownloadError.insufficientDiskCapacity(
                required: normalizedRequiredCapacity,
                available: availableCapacity
            )
        }
    }
}

actor HLSDiskCapacityGuard {
    private let checker: HLSDiskCapacityChecker
    private let directoryURL: URL
    private let policy: HLSDiskCapacityPolicy
    private var reservedCapacity: Int64 = 0

    init(
        checker: HLSDiskCapacityChecker,
        directoryURL: URL,
        policy: HLSDiskCapacityPolicy
    ) {
        self.checker = checker
        self.directoryURL = directoryURL
        self.policy = policy
    }

    func validate(additionalRequiredCapacity: Int64) throws {
        let required = combinedCapacity(
            additionalRequiredCapacity,
            reservedCapacity
        )
        try checker.validate(
            directoryURL: directoryURL,
            policy: policy,
            additionalRequiredCapacity: required
        )
    }

    func reserve(_ byteCount: Int) throws {
        guard policy != .disabled else {
            return
        }
        let bytes = Int64(byteCount)
        let nextReservedCapacity = combinedCapacity(
            reservedCapacity,
            bytes
        )
        try checker.validate(
            directoryURL: directoryURL,
            policy: policy,
            additionalRequiredCapacity: nextReservedCapacity
        )
        reservedCapacity = nextReservedCapacity
    }

    func release(_ byteCount: Int) {
        guard policy != .disabled else {
            return
        }
        reservedCapacity = max(0, reservedCapacity - Int64(byteCount))
    }

    private func combinedCapacity(
        _ lhs: Int64,
        _ rhs: Int64
    ) -> Int64 {
        let (result, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? .max : max(0, result)
    }
}
