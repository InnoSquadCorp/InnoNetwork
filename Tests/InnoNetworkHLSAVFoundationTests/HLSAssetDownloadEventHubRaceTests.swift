#if canImport(AVFoundation) && !os(tvOS)
import Foundation
import Testing

@testable import InnoNetworkHLSAVFoundation

@Suite("AVFoundation HLS event race gate")
struct HLSAssetDownloadEventHubRaceTests {
    @Test("concurrent progress and terminal delivery closes every observer")
    func concurrentTerminalDelivery() async {
        for iteration in 0..<64 {
            let hub = HLSAssetDownloadEventHub()
            let taskIdentifier = iteration
            let streams = (0..<8).map { _ in
                hub.stream(taskIdentifier: taskIdentifier)
            }
            let collectors = streams.map { stream in
                Task {
                    var terminalCount = 0
                    for await event in stream {
                        switch event {
                        case .completed, .failed, .cancelled:
                            terminalCount += 1
                        case .progress, .locationAvailable:
                            break
                        }
                    }
                    return terminalCount
                }
            }

            await withTaskGroup(of: Void.self) { group in
                for value in 0..<16 {
                    group.addTask {
                        hub.sendProgress(
                            Double(value) / 15,
                            taskIdentifier: taskIdentifier
                        )
                    }
                }
                for _ in 0..<4 {
                    group.addTask {
                        hub.sendTerminal(
                            .cancelled,
                            taskIdentifier: taskIdentifier
                        )
                    }
                }
            }

            for collector in collectors {
                #expect(await collector.value == 1)
            }
        }
    }
}
#endif
