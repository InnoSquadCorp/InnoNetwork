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
}

private struct BenchmarkOptions: Sendable {
    let quick: Bool
    let jsonOutputPath: String?
    let baselinePath: String

    static func parse(arguments: [String]) -> BenchmarkOptions {
        let defaultBaseline = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Baselines/default.json")
            .path

        var quick = false
        var jsonOutputPath: String?
        var baselinePath = defaultBaseline

        var iterator = arguments.makeIterator()
        while let argument = iterator.next() {
            switch argument {
            case "--quick":
                quick = true
            case "--json-path":
                jsonOutputPath = iterator.next()
            case "--baseline":
                if let override = iterator.next() {
                    baselinePath = override
                }
            default:
                break
            }
        }

        return BenchmarkOptions(
            quick: quick,
            jsonOutputPath: jsonOutputPath,
            baselinePath: baselinePath
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
        let options = BenchmarkOptions.parse(arguments: Array(CommandLine.arguments.dropFirst()))
        let results = try await runBenchmarks(options: options)
        let report = BenchmarkReport(
            version: 1,
            generatedAt: ISO8601DateFormatter().string(from: .now),
            results: results
        )

        print("InnoNetwork Benchmarks")
        for result in results {
            print(
                "- \(result.group)/\(result.name): " +
                "\(String(format: "%.2f", result.operationsPerSecond)) ops/s " +
                "(\(String(format: "%.4f", result.elapsedSeconds))s, n=\(result.iterations))"
            )
        }

        printBaselineDiff(report: report, baselinePath: options.baselinePath)

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
    }

    private static func runBenchmarks(options: BenchmarkOptions) async throws -> [BenchmarkResult] {
        var results: [BenchmarkResult] = []
        let encoderIterations = options.quick ? 2_000 : 20_000
        let eventIterations = options.quick ? 400 : 4_000
        let persistenceIterations = options.quick ? 300 : 3_000
        let reconnectIterations = options.quick ? 2_000 : 20_000

        results.append(try await measure(name: "query-encoder-small", group: "encoding", iterations: encoderIterations) {
            let encoder = URLQueryEncoder(keyEncodingStrategy: URLQueryKeyEncodingStrategy.convertToSnakeCase)
            let payload = SmallPayload.sample
            for _ in 0..<encoderIterations {
                _ = try encoder.encode(payload)
            }
        })

        results.append(try await measure(name: "query-encoder-large", group: "encoding", iterations: encoderIterations) {
            let encoder = URLQueryEncoder(keyEncodingStrategy: URLQueryKeyEncodingStrategy.convertToSnakeCase)
            let payload = LargePayload.sample
            for _ in 0..<encoderIterations {
                _ = try encoder.encode(payload)
            }
        })

        results.append(try await benchmarkTaskEventHubFanOut(iterations: eventIterations, listeners: 1, name: "task-event-fanout-single"))
        results.append(try await benchmarkTaskEventHubFanOut(iterations: eventIterations, listeners: 8, name: "task-event-fanout-many"))
        results.append(try await benchmarkTaskEventHubSlowIsolation(iterations: eventIterations))
        results.append(try await benchmarkPersistenceAppend(iterations: persistenceIterations))
        results.append(try await benchmarkPersistenceReplay(iterations: persistenceIterations))
        results.append(try await benchmarkPersistenceCompaction(iterations: max(1_050, persistenceIterations)))
        results.append(try await benchmarkReconnectDecision(iterations: reconnectIterations))
        results.append(try await benchmarkCloseDispositionClassify(iterations: reconnectIterations))
        results.append(try await benchmarkPingContextAlloc(iterations: reconnectIterations))

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
                await persistence.upsert(
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
            await seed.upsert(
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
                await persistence.upsert(
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

    private static func printBaselineDiff(report: BenchmarkReport, baselinePath: String) {
        let baselineURL = URL(fileURLWithPath: baselinePath)

        guard FileManager.default.fileExists(atPath: baselineURL.path) else {
            print("No baseline loaded from \(baselinePath) (file not found)")
            return
        }

        let data: Data
        do {
            data = try Data(contentsOf: baselineURL)
        } catch {
            print("No baseline loaded from \(baselinePath) (read failed: \(error.localizedDescription))")
            return
        }

        let baseline: BenchmarkReport
        do {
            baseline = try JSONDecoder().decode(BenchmarkReport.self, from: data)
        } catch {
            print("No baseline loaded from \(baselinePath) (schema mismatch: \(error.localizedDescription))")
            return
        }

        let baselineMap: [BenchmarkIdentifier: BenchmarkResult]
        do {
            baselineMap = try makeBenchmarkMap(from: baseline.results)
        } catch {
            print("No baseline loaded from \(baselinePath) (\(error.localizedDescription))")
            return
        }
        print("Baseline diff:")
        for result in report.results {
            let identifier = BenchmarkIdentifier(group: result.group, name: result.name)
            guard let baseline = baselineMap[identifier] else {
                print("- \(result.group)/\(result.name): no baseline entry")
                continue
            }
            let delta = ((result.operationsPerSecond - baseline.operationsPerSecond) / max(baseline.operationsPerSecond, 0.000_001)) * 100.0
            print("- \(result.group)/\(result.name): \(String(format: "%+.2f", delta))% vs baseline")
        }
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
                            "Duplicate benchmark identifier found for \(result.group)/\(result.name). " +
                            "Benchmark names must be unique within a group."
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
