import Foundation
import InnoNetwork
import InnoNetworkDownload
import InnoNetworkWebSocket

private struct BenchmarkResult: Codable, Sendable {
    let name: String
    let group: String
    let iterations: Int
    let elapsedSeconds: Double
    let operationsPerSecond: Double
}

private struct BenchmarkReport: Codable, Sendable {
    let version: Int
    let generatedAt: String
    let results: [BenchmarkResult]
}

private struct BenchmarkIdentifier: Hashable, Sendable {
    let group: String
    let name: String

    var displayName: String { "\(group)/\(name)" }

    static func parse(_ rawValue: String) throws -> BenchmarkIdentifier {
        let components = rawValue.split(separator: "/", maxSplits: 1).map(String.init)
        guard components.count == 2, !components[0].isEmpty, !components[1].isEmpty else {
            throw NSError(
                domain: "InnoNetworkBenchmarks",
                code: 2,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Invalid benchmark identifier '\(rawValue)'. Use the format group/name."
                ]
            )
        }
        return BenchmarkIdentifier(group: components[0], name: components[1])
    }
}

private struct BaselineComparison: Sendable {
    let identifier: BenchmarkIdentifier
    let deltaPercent: Double
    let isGuarded: Bool
}

private struct BenchmarkGuardFailure: Sendable {
    let identifier: BenchmarkIdentifier
    let deltaPercent: Double
    let maxRegressionPercent: Double
}

private struct BenchmarkOptions: Sendable {
    let quick: Bool
    let jsonOutputPath: String?
    let baselinePath: String
    let enforceBaseline: Bool
    let guardBenchmarks: Set<BenchmarkIdentifier>
    let maxRegressionPercent: Double

    static func parse(arguments: [String]) throws -> BenchmarkOptions {
        let defaultBaseline = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Baselines/default.json")
            .path

        var quick = false
        var jsonOutputPath: String?
        var baselinePath = defaultBaseline
        var enforceBaseline = false
        var guardBenchmarks: Set<BenchmarkIdentifier> = []
        var maxRegressionPercent = 0.0

        var iterator = arguments.makeIterator()
        func requiredValue(
            code: Int,
            description: String
        ) throws -> String {
            guard let value = iterator.next(), !value.hasPrefix("-") else {
                throw NSError(
                    domain: "InnoNetworkBenchmarks",
                    code: code,
                    userInfo: [
                        NSLocalizedDescriptionKey: description
                    ]
                )
            }
            return value
        }

        while let argument = iterator.next() {
            switch argument {
            case "--quick":
                quick = true
            case "--json-path":
                let path = try requiredValue(
                    code: 3,
                    description: "Missing path after --json-path."
                )
                jsonOutputPath = path
            case "--baseline":
                let override = try requiredValue(
                    code: 4,
                    description: "Missing path after --baseline."
                )
                baselinePath = override
            case "--enforce-baseline":
                enforceBaseline = true
            case "--guard-benchmark":
                let rawIdentifier = try requiredValue(
                    code: 5,
                    description: "Missing benchmark identifier after --guard-benchmark."
                )
                guardBenchmarks.insert(try BenchmarkIdentifier.parse(rawIdentifier))
            case "--max-regression-percent":
                let rawPercent = try requiredValue(
                    code: 6,
                    description: "Missing or invalid numeric value after --max-regression-percent."
                )
                guard let percent = Double(rawPercent), percent >= 0 else {
                    throw NSError(
                        domain: "InnoNetworkBenchmarks",
                        code: 6,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "Missing or invalid numeric value after --max-regression-percent."
                        ]
                    )
                }
                maxRegressionPercent = percent
            default:
                throw NSError(
                    domain: "InnoNetworkBenchmarks",
                    code: 13,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Unknown benchmark option '\(argument)'."
                    ]
                )
            }
        }

        return BenchmarkOptions(
            quick: quick,
            jsonOutputPath: jsonOutputPath,
            baselinePath: baselinePath,
            enforceBaseline: enforceBaseline,
            guardBenchmarks: guardBenchmarks,
            maxRegressionPercent: maxRegressionPercent
        )
    }
}

private actor BenchmarkCounter {
    private var value = 0
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var target = 0

    func reset(target: Int) {
        value = 0
        self.target = target
        continuations.removeAll(keepingCapacity: true)
    }

    func increment() {
        value += 1
        if value >= target {
            let pendingContinuations = continuations
            continuations.removeAll(keepingCapacity: true)
            for continuation in pendingContinuations {
                continuation.resume()
            }
        }
    }

    func wait() async {
        if value >= target { return }
        await withCheckedContinuation { continuation in
            self.continuations.append(continuation)
            if self.value >= self.target {
                let pendingContinuations = self.continuations
                self.continuations.removeAll(keepingCapacity: true)
                for pendingContinuation in pendingContinuations {
                    pendingContinuation.resume()
                }
            }
        }
    }
}

private enum InnoNetworkBenchmarks {
    static func runMain() async throws {
        let options = try BenchmarkOptions.parse(arguments: Array(CommandLine.arguments.dropFirst()))
        let results = try await runBenchmarks(options: options)
        let report = BenchmarkReport(
            version: 1,
            generatedAt: ISO8601DateFormatter().string(from: .now),
            results: results
        )

        print("InnoNetwork Benchmarks")
        for result in results {
            print(
                "- \(result.group)/\(result.name): " + "\(String(format: "%.2f", result.operationsPerSecond)) ops/s "
                    + "(\(String(format: "%.4f", result.elapsedSeconds))s, n=\(result.iterations))"
            )
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let jsonData = try encoder.encode(report)
        if let jsonOutputPath = options.jsonOutputPath {
            try jsonData.write(to: URL(fileURLWithPath: jsonOutputPath), options: .atomic)
            print("JSON summary written to \(jsonOutputPath)")
        }
        if let jsonString = String(data: jsonData, encoding: .utf8) {
            print(jsonString)
        }

        let guardFailures = try printBaselineDiff(report: report, options: options)
        if !guardFailures.isEmpty {
            let failureSummary =
                guardFailures
                .map { failure in
                    "\(failure.identifier.displayName) regressed by "
                        + "\(String(format: "%.2f", abs(failure.deltaPercent)))% "
                        + "(limit \(String(format: "%.2f", failure.maxRegressionPercent))%)"
                }
                .joined(separator: "; ")
            throw NSError(
                domain: "InnoNetworkBenchmarks",
                code: 7,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Baseline regression guard failed: \(failureSummary)"
                ]
            )
        }
    }

    private static func runBenchmarks(options: BenchmarkOptions) async throws -> [BenchmarkResult] {
        var results: [BenchmarkResult] = []
        let encoderIterations = options.quick ? 2_000 : 20_000
        let eventIterations = options.quick ? 400 : 4_000
        let persistenceIterations = options.quick ? 300 : 3_000
        let reconnectIterations = 20_000
        // The guarded websocket microbenchmarks were finishing in just a few
        // milliseconds in `--quick` mode, which made CI regressions overly
        // sensitive to runner scheduling noise. Keep the coarse smoke gate fast,
        // but run these two long enough that a brief preemption does not look
        // like a >20% regression.
        let websocketGuardIterations = options.quick ? 500_000 : 2_000_000

        results.append(
            try await measure(name: "query-encoder-small", group: "encoding", iterations: encoderIterations) {
                let encoder = URLQueryEncoder(keyEncodingStrategy: URLQueryKeyEncodingStrategy.convertToSnakeCase)
                let payload = SmallPayload.sample
                for _ in 0..<encoderIterations {
                    _ = try encoder.encode(payload)
                }
            })

        results.append(
            try await measure(name: "query-encoder-large", group: "encoding", iterations: encoderIterations) {
                let encoder = URLQueryEncoder(keyEncodingStrategy: URLQueryKeyEncodingStrategy.convertToSnakeCase)
                let payload = LargePayload.sample
                for _ in 0..<encoderIterations {
                    _ = try encoder.encode(payload)
                }
            })

        results.append(
            try await benchmarkTaskEventHubFanOut(
                iterations: eventIterations, listeners: 1, name: "task-event-fanout-single"))
        results.append(
            try await benchmarkTaskEventHubFanOut(
                iterations: eventIterations, listeners: 8, name: "task-event-fanout-many"))
        results.append(try await benchmarkTaskEventHubSlowIsolation(iterations: eventIterations))
        results.append(try await benchmarkPersistenceAppend(iterations: persistenceIterations))
        results.append(try await benchmarkPersistenceReplay(iterations: persistenceIterations))
        results.append(try await benchmarkPersistenceCompaction(iterations: max(1_050, persistenceIterations)))
        results.append(try await benchmarkReconnectDecision(iterations: reconnectIterations))
        results.append(try await benchmarkCloseDispositionClassify(iterations: websocketGuardIterations))
        results.append(try await benchmarkPingContextAlloc(iterations: websocketGuardIterations))
        let clientIterations = options.quick ? 2_000 : 20_000
        results.append(try await benchmarkConcurrentClientThroughput(iterations: clientIterations))

        return results
    }

    private static func measure(
        name: String,
        group: String,
        iterations: Int,
        work: () async throws -> Void
    ) async throws -> BenchmarkResult {
        let clock = ContinuousClock()
        let start = clock.now
        try await work()
        let elapsed = start.duration(to: clock.now)
        let elapsedSeconds = max(
            Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000_000.0,
            0.000_001
        )
        return BenchmarkResult(
            name: name,
            group: group,
            iterations: iterations,
            elapsedSeconds: elapsedSeconds,
            operationsPerSecond: Double(iterations) / elapsedSeconds
        )
    }

    private static func benchmarkTaskEventHubFanOut(
        iterations: Int,
        listeners: Int,
        name: String
    ) async throws -> BenchmarkResult {
        try await measure(name: name, group: "events", iterations: iterations) {
            let hub = TaskEventHub<String>(
                policy: EventDeliveryPolicy(
                    maxBufferedEventsPerPartition: max(1_024, iterations),
                    maxBufferedEventsPerConsumer: max(1_024, iterations),
                    overflowPolicy: .dropOldest
                )
            )
            let counter = BenchmarkCounter()
            await counter.reset(target: iterations * listeners)
            for _ in 0..<listeners {
                _ = await hub.addListener(taskID: "fanout") { _ in
                    await counter.increment()
                }
            }
            for index in 0..<iterations {
                await hub.publish("event-\(index)", for: "fanout")
            }
            await counter.wait()
            await hub.finish(taskID: "fanout")
        }
    }

    private static func benchmarkTaskEventHubSlowIsolation(iterations: Int) async throws -> BenchmarkResult {
        try await measure(name: "task-event-slow-isolation", group: "events", iterations: iterations) {
            let hub = TaskEventHub<String>(
                policy: EventDeliveryPolicy(
                    maxBufferedEventsPerPartition: max(1_024, iterations),
                    maxBufferedEventsPerConsumer: max(1_024, iterations),
                    overflowPolicy: .dropOldest
                )
            )
            let fastCounter = BenchmarkCounter()
            await fastCounter.reset(target: iterations)
            _ = await hub.addListener(taskID: "fast") { _ in
                await fastCounter.increment()
            }
            _ = await hub.addListener(taskID: "slow") { _ in
                try? await Task.sleep(for: .milliseconds(1))
            }
            for index in 0..<iterations {
                await hub.publish("fast-\(index)", for: "fast")
                await hub.publish("slow-\(index)", for: "slow")
            }
            await fastCounter.wait()
            await hub.finish(taskID: "fast")
            await hub.finish(taskID: "slow")
        }
    }

    private static func benchmarkPersistenceAppend(iterations: Int) async throws -> BenchmarkResult {
        let directory = try makeTemporaryDirectory(prefix: "append")
        defer { try? FileManager.default.removeItem(at: directory) }

        return try await measure(name: "append-log-write", group: "persistence", iterations: iterations) {
            let persistence = DownloadTaskPersistence(
                sessionIdentifier: "bench.append",
                baseDirectoryURL: directory
            )
            for index in 0..<iterations {
                try await persistence.upsert(
                    id: "task-\(index)",
                    url: URL(string: "https://example.com/\(index)")!,
                    destinationURL: directory.appendingPathComponent("file-\(index)")
                )
            }
        }
    }

    private static func benchmarkPersistenceReplay(iterations: Int) async throws -> BenchmarkResult {
        let directory = try makeTemporaryDirectory(prefix: "replay")
        defer { try? FileManager.default.removeItem(at: directory) }

        let seed = DownloadTaskPersistence(sessionIdentifier: "bench.replay", baseDirectoryURL: directory)
        for index in 0..<iterations {
            try await seed.upsert(
                id: "task-\(index)",
                url: URL(string: "https://example.com/\(index)")!,
                destinationURL: directory.appendingPathComponent("file-\(index)")
            )
        }

        return try await measure(name: "append-log-replay", group: "persistence", iterations: iterations) {
            let replayed = DownloadTaskPersistence(sessionIdentifier: "bench.replay", baseDirectoryURL: directory)
            for _ in 0..<iterations {
                _ = await replayed.allRecords()
            }
        }
    }

    private static func benchmarkPersistenceCompaction(iterations: Int) async throws -> BenchmarkResult {
        let directory = try makeTemporaryDirectory(prefix: "compact")
        defer { try? FileManager.default.removeItem(at: directory) }

        return try await measure(name: "append-log-compaction", group: "persistence", iterations: iterations) {
            let persistence = DownloadTaskPersistence(
                sessionIdentifier: "bench.compact",
                baseDirectoryURL: directory
            )
            for index in 0..<iterations {
                try await persistence.upsert(
                    id: "task-\(index)",
                    url: URL(string: "https://example.com/\(index)")!,
                    destinationURL: directory.appendingPathComponent("file-\(index)")
                )
            }
        }
    }

    private static func benchmarkReconnectDecision(iterations: Int) async throws -> BenchmarkResult {
        try await measure(name: "websocket-reconnect-decision", group: "websocket", iterations: iterations) {
            let runtimeRegistry = WebSocketRuntimeRegistry()
            let coordinator = WebSocketReconnectCoordinator(
                configuration: .advanced {
                    $0.reconnectDelay = 0
                    $0.maxReconnectAttempts = max(iterations, 8)
                },
                runtimeRegistry: runtimeRegistry
            )

            for index in 0..<iterations {
                let task = WebSocketTask(url: URL(string: "wss://example.com/socket")!, id: "bench-\(index)")
                _ = await coordinator.reconnectAction(
                    task: task,
                    closeDisposition: .handshakeServerUnavailable(503),
                    previousState: .connecting
                )
            }
        }
    }

    /// Measures the cost of the package-internal close-code classifier,
    /// which runs on every disconnect. Exercises the three branches
    /// (normal / retryable / terminal) so any one of them regressing shows
    /// up here.
    private static func benchmarkCloseDispositionClassify(iterations: Int) async throws -> BenchmarkResult {
        try await measure(name: "websocket-close-disposition-classify", group: "websocket", iterations: iterations) {
            let codes: [WebSocketCloseCode] = [
                .normalClosure,
                .serviceRestart,
                .tryAgainLater,
                .policyViolation,
                .custom(4001),
            ]
            for index in 0..<iterations {
                let code = codes[index % codes.count]
                _ = WebSocketCloseDisposition.classifyPeerClose(code, reason: nil)
            }
        }
    }

    /// Measures the cost of allocating a `WebSocketPingContext` — dominated
    /// by the `ContinuousClock.now` read. Heartbeat loops emit this on every
    /// cycle so it is a natural regression-guard target.
    private static func benchmarkPingContextAlloc(iterations: Int) async throws -> BenchmarkResult {
        try await measure(name: "websocket-ping-context-alloc", group: "websocket", iterations: iterations) {
            var attempt = 0
            for _ in 0..<iterations {
                attempt &+= 1
                let context = WebSocketPingContext(
                    attemptNumber: attempt,
                    dispatchedAt: .now
                )
                _ = context.attemptNumber
            }
        }
    }

    /// Measures end-to-end throughput of `DefaultNetworkClient.request(_:)`
    /// using an in-memory URL session that returns a fixed JSON payload.
    /// Captures the dispatch + retry-coordinator + event-hub + decode path
    /// without any network or kernel I/O, so regressions in the actor /
    /// class isolation model surface here before they show up in production.
    private static func benchmarkConcurrentClientThroughput(iterations: Int) async throws -> BenchmarkResult {
        try await measure(name: "concurrent-50-requests", group: "client", iterations: iterations) {
            let session = InstantMockSession.shared
            let client = DefaultNetworkClient(
                configuration: NetworkConfiguration.safeDefaults(
                    baseURL: URL(string: "https://benchmark.invalid")!
                ),
                session: session
            )
            let parallelism = 50
            let batches = max(1, iterations / parallelism)
            for _ in 0..<batches {
                await withTaskGroup(of: Void.self) { group in
                    for _ in 0..<parallelism {
                        group.addTask {
                            _ = try? await client.request(BenchmarkUserRequest())
                        }
                    }
                }
            }
        }
    }

    private static func printBaselineDiff(
        report: BenchmarkReport,
        options: BenchmarkOptions
    ) throws -> [BenchmarkGuardFailure] {
        let baselineURL = URL(fileURLWithPath: options.baselinePath)

        guard FileManager.default.fileExists(atPath: baselineURL.path) else {
            if options.enforceBaseline {
                throw NSError(
                    domain: "InnoNetworkBenchmarks",
                    code: 8,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "No baseline loaded from \(options.baselinePath) (file not found)"
                    ]
                )
            }
            print("No baseline loaded from \(options.baselinePath) (file not found)")
            return []
        }

        let data: Data
        do {
            data = try Data(contentsOf: baselineURL)
        } catch {
            if options.enforceBaseline {
                throw NSError(
                    domain: "InnoNetworkBenchmarks",
                    code: 9,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "No baseline loaded from \(options.baselinePath) "
                            + "(read failed: \(error.localizedDescription))"
                    ]
                )
            }
            print("No baseline loaded from \(options.baselinePath) (read failed: \(error.localizedDescription))")
            return []
        }

        let baseline: BenchmarkReport
        do {
            baseline = try JSONDecoder().decode(BenchmarkReport.self, from: data)
        } catch {
            if options.enforceBaseline {
                throw NSError(
                    domain: "InnoNetworkBenchmarks",
                    code: 10,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "No baseline loaded from \(options.baselinePath) "
                            + "(schema mismatch: \(error.localizedDescription))"
                    ]
                )
            }
            print("No baseline loaded from \(options.baselinePath) (schema mismatch: \(error.localizedDescription))")
            return []
        }

        let baselineMap: [BenchmarkIdentifier: BenchmarkResult]
        do {
            baselineMap = try makeBenchmarkMap(from: baseline.results)
        } catch {
            if options.enforceBaseline {
                throw error
            }
            print("No baseline loaded from \(options.baselinePath) (\(error.localizedDescription))")
            return []
        }

        let currentMap = try makeBenchmarkMap(from: report.results)
        print("Baseline diff:")
        let guardedIdentifiers: Set<BenchmarkIdentifier>
        if options.enforceBaseline {
            guardedIdentifiers =
                options.guardBenchmarks.isEmpty
                ? Set(currentMap.keys)
                : options.guardBenchmarks
        } else {
            guardedIdentifiers = options.guardBenchmarks
        }
        var comparisons: [BaselineComparison] = []
        for result in report.results {
            let identifier = BenchmarkIdentifier(group: result.group, name: result.name)
            guard let baseline = baselineMap[identifier] else {
                if options.enforceBaseline, guardedIdentifiers.contains(identifier) {
                    throw NSError(
                        domain: "InnoNetworkBenchmarks",
                        code: 11,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "Missing baseline entry for guarded benchmark \(identifier.displayName)."
                        ]
                    )
                }
                print("- \(result.group)/\(result.name): no baseline entry")
                continue
            }
            let delta =
                ((result.operationsPerSecond - baseline.operationsPerSecond)
                    / max(baseline.operationsPerSecond, 0.000_001)) * 100.0
            let isGuarded = guardedIdentifiers.contains(identifier)
            let guardLabel = isGuarded ? " [guard]" : ""
            print("- \(identifier.displayName): \(String(format: "%+.2f", delta))% vs baseline\(guardLabel)")
            comparisons.append(
                BaselineComparison(
                    identifier: identifier,
                    deltaPercent: delta,
                    isGuarded: isGuarded
                )
            )
        }

        let missingGuardedBenchmarks = guardedIdentifiers.subtracting(Set(comparisons.map(\.identifier))).filter {
            currentMap[$0] == nil || baselineMap[$0] == nil
        }
        if options.enforceBaseline, !missingGuardedBenchmarks.isEmpty {
            let missingNames =
                missingGuardedBenchmarks
                .map(\.displayName)
                .sorted()
                .joined(separator: ", ")
            throw NSError(
                domain: "InnoNetworkBenchmarks",
                code: 12,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Guarded benchmark missing from current run or baseline: \(missingNames)"
                ]
            )
        }

        guard options.enforceBaseline else { return [] }

        let failures = comparisons.compactMap { comparison -> BenchmarkGuardFailure? in
            guard comparison.isGuarded else { return nil }
            guard comparison.deltaPercent < 0 else { return nil }
            let regression = abs(comparison.deltaPercent)
            guard regression > options.maxRegressionPercent else { return nil }
            return BenchmarkGuardFailure(
                identifier: comparison.identifier,
                deltaPercent: comparison.deltaPercent,
                maxRegressionPercent: options.maxRegressionPercent
            )
        }

        if !failures.isEmpty {
            print("Baseline guard failures:")
            for failure in failures {
                print(
                    "- \(failure.identifier.displayName): "
                        + "\(String(format: "%+.2f", failure.deltaPercent))% vs baseline "
                        + "(limit \(String(format: "%.2f", failure.maxRegressionPercent))%)"
                )
            }
        }

        return failures
    }

    private static func makeBenchmarkMap(
        from results: [BenchmarkResult]
    ) throws -> [BenchmarkIdentifier: BenchmarkResult] {
        var map: [BenchmarkIdentifier: BenchmarkResult] = [:]
        for result in results {
            let identifier = BenchmarkIdentifier(group: result.group, name: result.name)
            guard map.updateValue(result, forKey: identifier) == nil else {
                throw NSError(
                    domain: "InnoNetworkBenchmarks",
                    code: 1,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Duplicate benchmark identifier found for \(result.group)/\(result.name). "
                            + "Benchmark names must be unique within a group."
                    ]
                )
            }
        }
        return map
    }

    private static func makeTemporaryDirectory(prefix: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("InnoNetworkBenchmarks-\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

try await InnoNetworkBenchmarks.runMain()

private struct SmallPayload: Encodable, Sendable {
    let userID: Int
    let includeDrafts: Bool
    let tags: [String]

    static let sample = SmallPayload(
        userID: 42,
        includeDrafts: true,
        tags: ["swift", "network", "benchmark"]
    )
}

private struct BenchmarkUser: Codable, Sendable {
    let id: Int
    let name: String
}

private struct BenchmarkUserRequest: APIDefinition {
    typealias Parameter = EmptyParameter
    typealias APIResponse = BenchmarkUser

    var method: HTTPMethod { .get }
    var path: String { "/users/1" }
}

/// `URLSessionProtocol` stub that returns a fixed JSON payload immediately,
/// without any kernel I/O. Used by the throughput benchmark to isolate the
/// dispatch / retry / event-hub / decode path from actual networking.
private final class InstantMockSession: URLSessionProtocol, @unchecked Sendable {
    static let shared = InstantMockSession()

    private let payload: Data
    private let response: HTTPURLResponse

    init() {
        self.payload = Data(#"{"id":1,"name":"benchmark"}"#.utf8)
        self.response = HTTPURLResponse(
            url: URL(string: "https://benchmark.invalid/users/1")!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        (payload, response)
    }
}

private struct LargePayload: Encodable, Sendable {
    struct Filter: Encodable, Sendable {
        let minAge: Int
        let maxAge: Int
        let regionCode: String
    }

    let userID: Int
    let includeDrafts: Bool
    let createdAt: Date
    let tags: [String]
    let filters: [Filter]

    static let sample = LargePayload(
        userID: 42,
        includeDrafts: true,
        createdAt: .now,
        tags: (0..<12).map { "tag-\($0)" },
        filters: (0..<12).map {
            Filter(minAge: $0, maxAge: $0 + 10, regionCode: "region-\($0)")
        }
    )
}
