import Foundation

struct HLSDateRangeScheduleResolver: Sendable {
    private let loader: HLSExternalResourceLoader
    private let settings: HLSExternalResourceSettings

    init(
        loader: HLSExternalResourceLoader,
        settings: HLSExternalResourceSettings
    ) {
        self.loader = loader
        self.settings = settings
    }

    func preload(
        _ dateRange: HLSDateRange
    ) async throws -> HLSPreloadedDateRangeResource {
        guard let preload = dateRange.preload, preload.isEligible else {
            throw HLSExternalResourceError.invalidDateRangePreload
        }
        let data = try await loader.load(
            from: preload.resource.url,
            purpose: .dateRangePreloadResource,
            accept: "*/*",
            maximumBytes: settings.maximumDateRangeResourceBytes
        )
        return HLSPreloadedDateRangeResource(
            sourceURL: preload.resource.url,
            targetID: preload.targetID,
            targetClass: preload.targetClass,
            data: data
        )
    }

    func resolve(
        _ schedule: HLSDateRange,
        preloadedResource: HLSPreloadedDateRangeResource?,
        startOffset: TimeInterval?,
        occupiedDateRangeIDs: Set<String>
    ) async throws -> HLSDateRangeSchedule {
        if let startOffset {
            guard startOffset.isFinite, startOffset >= 0 else {
                throw HLSExternalResourceError
                    .invalidDateRangeScheduleStartOffset
            }
        }
        let state = HLSDateRangeScheduleResolutionState(
            maximumEntryCount:
                settings.maximumScheduledDateRangeCount,
            occupiedIDs:
                occupiedDateRangeIDs.union([schedule.id])
        )
        return try await resolve(
            schedule,
            preloadedResource: preloadedResource,
            startOffset: startOffset,
            depth: 1,
            effectiveEndDate: Self.endDate(of: schedule),
            ancestorURLs: [],
            state: state
        )
    }

    private func resolve(
        _ schedule: HLSDateRange,
        preloadedResource: HLSPreloadedDateRangeResource?,
        startOffset: TimeInterval?,
        depth: Int,
        effectiveEndDate: Date?,
        ancestorURLs: Set<URL>,
        state: HLSDateRangeScheduleResolutionState
    ) async throws -> HLSDateRangeSchedule {
        guard
            schedule.className
                == HLSTimelineParser.dateRangeScheduleClass,
            let resource = schedule.externalResource
        else {
            throw HLSExternalResourceError.invalidDateRangeSchedule
        }
        guard depth <= settings.maximumDateRangeScheduleDepth else {
            throw
                HLSExternalResourceError
                .dateRangeScheduleDepthExceeded(
                    limit: settings.maximumDateRangeScheduleDepth
                )
        }
        guard !ancestorURLs.contains(resource.url) else {
            throw HLSExternalResourceError.dateRangeScheduleCycle
        }
        var nextAncestorURLs = ancestorURLs
        nextAncestorURLs.insert(resource.url)

        let data: Data
        if let preloadedResource,
            preloadedResource.matches(schedule)
        {
            data = preloadedResource.data
        } else {
            data = try await loader.load(
                from: try requestURL(
                    resource.url,
                    startOffset: startOffset
                ),
                purpose: .dateRangeSchedule,
                accept: "application/json",
                maximumBytes:
                    settings.maximumDateRangeResourceBytes
            )
        }
        let dateRanges = try HLSDateRangeScheduleDecoder.decode(
            data,
            parent: schedule,
            relativeTo: resource.url,
            maximumEntryCount:
                settings.maximumScheduledDateRangeCount
        )

        var entries: [HLSDateRangeScheduleEntry] = []
        entries.reserveCapacity(dateRanges.count)
        for dateRange in dateRanges {
            try await state.register(dateRange.id)
            guard
                Self.isWithinParent(
                    dateRange.startDate,
                    parent: schedule,
                    effectiveEndDate: effectiveEndDate
                )
            else {
                continue
            }
            try Self.validateCues(
                of: dateRange,
                in: schedule
            )

            let nestedSchedule: HLSDateRangeSchedule?
            if dateRange.className
                == HLSTimelineParser.dateRangeScheduleClass
            {
                nestedSchedule = try await resolve(
                    dateRange,
                    preloadedResource: nil,
                    startOffset: nil,
                    depth: depth + 1,
                    effectiveEndDate: Self.clippedEndDate(
                        of: dateRange,
                        to: effectiveEndDate
                    ),
                    ancestorURLs: nextAncestorURLs,
                    state: state
                )
            } else {
                nestedSchedule = nil
            }
            entries.append(
                HLSDateRangeScheduleEntry(
                    dateRange: dateRange,
                    nestedSchedule: nestedSchedule
                )
            )
        }
        return HLSDateRangeSchedule(
            source: schedule,
            entries: entries
        )
    }

    private func requestURL(
        _ url: URL,
        startOffset: TimeInterval?
    ) throws -> URL {
        guard let startOffset else {
            return url
        }
        guard
            var components = URLComponents(
                url: url,
                resolvingAgainstBaseURL: false
            )
        else {
            throw HLSExternalResourceError.invalidDateRangeSchedule
        }
        var queryItems = components.queryItems ?? []
        queryItems.removeAll {
            $0.name == "_HLS_start_offset"
        }
        queryItems.append(
            URLQueryItem(
                name: "_HLS_start_offset",
                value: String(startOffset)
            )
        )
        components.queryItems = queryItems
        guard let result = components.url else {
            throw HLSExternalResourceError.invalidDateRangeSchedule
        }
        return result
    }

    private static func isWithinParent(
        _ startDate: Date,
        parent: HLSDateRange,
        effectiveEndDate: Date?
    ) -> Bool {
        guard startDate >= parent.startDate else {
            return false
        }
        guard let effectiveEndDate else {
            return true
        }
        return startDate < effectiveEndDate
    }

    private static func endDate(
        of dateRange: HLSDateRange
    ) -> Date? {
        dateRange.endDate
            ?? dateRange.duration.map {
                dateRange.startDate.addingTimeInterval($0)
            }
    }

    private static func clippedEndDate(
        of dateRange: HLSDateRange,
        to parentEndDate: Date?
    ) -> Date? {
        switch (endDate(of: dateRange), parentEndDate) {
        case (.some(let dateRangeEnd), .some(let parentEnd)):
            return min(dateRangeEnd, parentEnd)
        case (.some(let dateRangeEnd), nil):
            return dateRangeEnd
        case (nil, .some(let parentEnd)):
            return parentEnd
        case (nil, nil):
            return nil
        }
    }

    private static func validateCues(
        of dateRange: HLSDateRange,
        in schedule: HLSDateRange
    ) throws {
        if dateRange.cues.contains(.pre),
            !schedule.cues.contains(.pre)
        {
            throw HLSExternalResourceError.invalidDateRangeSchedule
        }
        if schedule.cues.contains(.post),
            !dateRange.cues.contains(.post)
        {
            throw HLSExternalResourceError.invalidDateRangeSchedule
        }
        if schedule.cues.contains(.post),
            dateRange.cues.contains(.pre)
        {
            throw HLSExternalResourceError.invalidDateRangeSchedule
        }
    }
}

private actor HLSDateRangeScheduleResolutionState {
    private let maximumEntryCount: Int
    private var occupiedIDs: Set<String>
    private var entryCount = 0

    init(
        maximumEntryCount: Int,
        occupiedIDs: Set<String>
    ) {
        self.maximumEntryCount = maximumEntryCount
        self.occupiedIDs = occupiedIDs
    }

    func register(_ id: String) throws {
        guard occupiedIDs.insert(id).inserted else {
            throw HLSExternalResourceError
                .duplicateScheduledDateRangeIdentifier
        }
        entryCount += 1
        guard entryCount <= maximumEntryCount else {
            throw
                HLSExternalResourceError
                .tooManyScheduledDateRanges(
                    limit: maximumEntryCount
                )
        }
    }
}
