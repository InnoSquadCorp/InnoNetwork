import Foundation

struct HLSLiveReloadRequest {
    let url: URL
    let mode: HLSLiveReloadMode

    var usesBlockingReload: Bool {
        mode == .blocking || mode == .blockingPartial
            || mode == .cdnTuneIn
    }
}

enum HLSLiveReloadRequestBuilder {
    private static let reloadQueryNames: Set<String> = [
        "_HLS_msn",
        "_HLS_part",
        "_HLS_skip",
    ]

    static func nextRequest(
        after snapshot: HLSLivePlaylistSnapshot,
        settings: HLSLiveReloadSettings
    ) throws -> HLSLiveReloadRequest {
        var components = try components(
            for: snapshot.playlist.sourceURL
        )
        var queryItems = (components.queryItems ?? []).filter {
            !reloadQueryNames.contains($0.name)
        }

        let canBlock =
            settings.prefersBlockingReloads
            && snapshot.playlist.lowLatency?
                .serverControl?.canBlockReload == true
        var mode = HLSLiveReloadMode.polling
        if canBlock,
            let position = try blockingPosition(after: snapshot)
        {
            mode =
                position.partIndex == nil
                ? .blocking
                : .blockingPartial
            queryItems.append(
                URLQueryItem(
                    name: "_HLS_msn",
                    value: String(position.mediaSequenceNumber)
                )
            )
            if let partIndex = position.partIndex {
                queryItems.append(
                    URLQueryItem(
                        name: "_HLS_part",
                        value: String(partIndex)
                    )
                )
            }
        }

        if settings.allowsDeltaUpdates,
            let serverControl =
                snapshot.playlist.lowLatency?.serverControl,
            serverControl.canSkipUntil != nil
        {
            queryItems.append(
                URLQueryItem(
                    name: "_HLS_skip",
                    value:
                        serverControl.canSkipDateRanges
                        ? "v2"
                        : "YES"
                )
            )
        }
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        guard let url = components.url else {
            throw HLSLiveError.invalidReloadURL
        }
        return HLSLiveReloadRequest(
            url: url,
            mode: mode
        )
    }

    static func fullReloadURL(
        from url: URL
    ) throws -> URL {
        var components = try components(for: url)
        let queryItems = (components.queryItems ?? []).filter {
            !reloadQueryNames.contains($0.name)
        }
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        guard let url = components.url else {
            throw HLSLiveError.invalidReloadURL
        }
        return url
    }

    static func tuneInURL(
        for destinationURL: URL,
        using snapshot: HLSLivePlaylistSnapshot
    ) throws -> URL {
        guard
            let report = snapshot.playlist.lowLatency?
                .renditionReports.first(where: {
                    equivalentPlaylistURL(
                        $0.url,
                        destinationURL
                    )
                }),
            let mediaSequenceNumber =
                report.lastMediaSequenceNumber
        else {
            return try fullReloadURL(from: destinationURL)
        }
        var components = try components(for: destinationURL)
        var queryItems = (components.queryItems ?? []).filter {
            !reloadQueryNames.contains($0.name)
        }
        queryItems.append(
            URLQueryItem(
                name: "_HLS_msn",
                value: String(mediaSequenceNumber)
            )
        )
        if let partIndex = report.lastPartialSegmentIndex {
            queryItems.append(
                URLQueryItem(
                    name: "_HLS_part",
                    value: String(partIndex)
                )
            )
        }
        components.queryItems = queryItems
        guard let url = components.url else {
            throw HLSLiveError.invalidReloadURL
        }
        return url
    }

    static func cdnTuneInRequest(
        from sourceURL: URL,
        mediaSequenceNumber: Int64,
        partIndex: Int
    ) throws -> HLSLiveReloadRequest {
        var components = try components(for: sourceURL)
        var queryItems = (components.queryItems ?? []).filter {
            !reloadQueryNames.contains($0.name)
        }
        queryItems.append(
            URLQueryItem(
                name: "_HLS_msn",
                value: String(mediaSequenceNumber)
            )
        )
        queryItems.append(
            URLQueryItem(
                name: "_HLS_part",
                value: String(partIndex)
            )
        )
        components.queryItems = queryItems
        guard let url = components.url else {
            throw HLSLiveError.invalidReloadURL
        }
        return HLSLiveReloadRequest(
            url: url,
            mode: .cdnTuneIn
        )
    }

    static func pollingDelay(
        after snapshot: HLSLivePlaylistSnapshot,
        settings: HLSLiveReloadSettings
    ) -> Duration {
        let suggested =
            snapshot.playlist.targetDuration.map {
                TimeInterval($0) / 2
            } ?? settings.minimumPollingInterval
        let interval = min(
            settings.maximumPollingInterval,
            max(settings.minimumPollingInterval, suggested)
        )
        return .milliseconds(Int64((interval * 1_000).rounded()))
    }

    private static func blockingPosition(
        after snapshot: HLSLivePlaylistSnapshot
    ) throws -> (
        mediaSequenceNumber: Int64,
        partIndex: Int?
    )? {
        guard let edge = try HLSLiveMediaEdge.latest(in: snapshot) else {
            return nil
        }
        return (
            edge.mediaSequenceNumber,
            edge.partBoundaryIndex == 0
                ? nil
                : edge.partBoundaryIndex
        )
    }

    private static func components(
        for url: URL
    ) throws -> URLComponents {
        guard
            let components = URLComponents(
                url: url,
                resolvingAgainstBaseURL: false
            )
        else {
            throw HLSLiveError.invalidReloadURL
        }
        return components
    }

    private static func equivalentPlaylistURL(
        _ lhs: URL,
        _ rhs: URL
    ) -> Bool {
        guard
            var lhsComponents = URLComponents(
                url: lhs,
                resolvingAgainstBaseURL: false
            ),
            var rhsComponents = URLComponents(
                url: rhs,
                resolvingAgainstBaseURL: false
            )
        else {
            return false
        }
        lhsComponents.queryItems = (lhsComponents.queryItems ?? []).filter {
            !reloadQueryNames.contains($0.name)
        }
        rhsComponents.queryItems = (rhsComponents.queryItems ?? []).filter {
            !reloadQueryNames.contains($0.name)
        }
        return lhsComponents == rhsComponents
    }
}
