#if canImport(AVFoundation)
import AVFoundation
import Foundation
import Testing

@testable import InnoNetworkHLSAVFoundation

@Suite("AVFoundation HLS timed metadata")
struct HLSTimedMetadataTests {
    @Test("identifiers reject unsafe schema names")
    func identifiersRejectUnsafeSchemaNames() {
        #expect(HLSTimedMetadataIdentifier("") == nil)
        #expect(HLSTimedMetadataIdentifier("id3/TIT2\nsecret") == nil)
        #expect(
            HLSTimedMetadataIdentifier(String(repeating: "a", count: 513))
                == nil
        )
        #expect(
            HLSTimedMetadataIdentifier("com.example/chapter")?.rawValue
                == "com.example/chapter"
        )
    }

    @Test("safe defaults allowlist identifiers without exposing values")
    func safeDefaultsRedactValues() {
        let configuration = HLSTimedMetadataConfiguration.safeDefaults(
            identifiers: [
                .id3Title,
                .id3Private,
                .id3Title,
            ]
        )

        #expect(
            configuration.fields
                == [
                    .redacted(.id3Title),
                    .redacted(.id3Private),
                ]
        )
        #expect(configuration.maximumBufferedEventCount == 64)
        #expect(configuration.maximumItemCountPerGroup == 64)
        #expect(configuration.advanceInterval == 0)
    }

    @Test("advanced configuration is bounded and first-field wins")
    func advancedConfigurationIsBounded() {
        let configuration = HLSTimedMetadataConfiguration.advanced(
            fields: [
                .text(.id3Title, maximumUTF8ByteCount: 0),
                .number(.id3Title),
                .date(.id3AlbumTitle),
            ],
            advanceInterval: 90,
            maximumBufferedEventCount: 0,
            maximumItemCountPerGroup: 2_000
        )

        #expect(
            configuration.fields
                == [
                    .text(.id3Title, maximumUTF8ByteCount: 1),
                    .date(.id3AlbumTitle),
                ]
        )
        #expect(configuration.advanceInterval == 60)
        #expect(configuration.maximumBufferedEventCount == 1)
        #expect(configuration.maximumItemCountPerGroup == 1_024)

        let nonFinite = HLSTimedMetadataConfiguration.advanced(
            fields: [],
            advanceInterval: .infinity
        )
        #expect(nonFinite.advanceInterval == 0)
    }

    @Test("duplicate identifiers do not consume the unique field limit")
    func duplicateIdentifiersDoNotConsumeFieldLimit() {
        let customIdentifiers = (0..<300).compactMap {
            HLSTimedMetadataIdentifier("test/FIELD-\($0)")
        }
        let fields =
            Array(
                repeating: HLSTimedMetadataField.redacted(.id3Title),
                count: 300
            )
            + customIdentifiers.map(HLSTimedMetadataField.redacted)

        let configuration = HLSTimedMetadataConfiguration.advanced(
            fields: fields
        )

        #expect(configuration.fields.count == 256)
        #expect(configuration.fields.first == .redacted(.id3Title))
        #expect(
            configuration.fields.last?.identifier
                == customIdentifiers[254]
        )
    }

    @Test("language tags are bounded and control-character free")
    func languageTagsAreBounded() {
        #expect(HLSTimedMetadataMapper.boundedLanguageTag("ko-KR") == "ko-KR")
        #expect(HLSTimedMetadataMapper.boundedLanguageTag("") == nil)
        #expect(
            HLSTimedMetadataMapper.boundedLanguageTag("ko\nKR") == nil
        )
        #expect(
            HLSTimedMetadataMapper.boundedLanguageTag(
                String(repeating: "a", count: 129)
            ) == nil
        )
    }

    @Test("mapper exposes only allowlisted bounded representations")
    func mapperExposesOnlyAllowlistedValues() async {
        let title = metadataItem(
            identifier: .id3MetadataTitleDescription,
            value: NSString(string: "가나다라마바사"),
            languageTag: "ko",
            time: 2,
            duration: 1
        )
        let privateData = metadataItem(
            identifier: .id3MetadataPrivate,
            value: NSData(data: Data([0, 1, 2])),
            languageTag: "private-language",
            time: 2,
            duration: 1
        )
        let ignoredArtist = metadataItem(
            identifier: .id3MetadataLeadPerformer,
            value: NSString(string: "not allowlisted"),
            time: 2,
            duration: 1
        )
        let group = AVTimedMetadataGroup(
            items: [title, privateData, ignoredArtist],
            timeRange: CMTimeRange(
                start: CMTime(seconds: 2, preferredTimescale: 600),
                duration: .indefinite
            )
        )
        let configuration = HLSTimedMetadataConfiguration.advanced(
            fields: [
                .text(.id3Title, maximumUTF8ByteCount: 7),
                .redacted(.id3Private),
            ]
        )

        let events = await HLSTimedMetadataMapper.map(
            [group],
            source: .track,
            configuration: configuration
        )

        #expect(events.count == 1)
        guard case .metadata(let mapped)? = events.first else {
            Issue.record("Expected one mapped metadata group")
            return
        }
        #expect(mapped.source == HLSTimedMetadataSource.track)
        #expect(mapped.startTime == 2)
        #expect(mapped.duration == nil)
        #expect(mapped.didTruncateItems == false)
        #expect(mapped.items.count == 2)
        #expect(
            mapped.items[0].identifier
                == HLSTimedMetadataIdentifier.id3Title
        )
        #expect(
            mapped.items[0].value
                == HLSTimedMetadataValue.text(
                    "가나",
                    wasTruncated: true
                )
        )
        #expect(mapped.items[0].languageTag == "ko")
        #expect(mapped.items[0].startTime == 2)
        #expect(mapped.items[0].duration == 1)
        #expect(
            mapped.items[1].identifier
                == HLSTimedMetadataIdentifier.id3Private
        )
        #expect(
            mapped.items[1].value
                == HLSTimedMetadataValue.redacted
        )
        #expect(mapped.items[1].languageTag == nil)
    }

    @Test("mapper marks allowlisted item truncation")
    func mapperMarksItemTruncation() async {
        let first = metadataItem(
            identifier: .id3MetadataTitleDescription,
            value: NSString(string: "first")
        )
        let second = metadataItem(
            identifier: .id3MetadataTitleDescription,
            value: NSString(string: "second")
        )
        let group = AVTimedMetadataGroup(
            items: [first, second],
            timeRange: .zero
        )
        let configuration = HLSTimedMetadataConfiguration.advanced(
            fields: [.redacted(.id3Title)],
            maximumItemCountPerGroup: 1
        )

        let events = await HLSTimedMetadataMapper.map(
            [group],
            source: .asset,
            configuration: configuration
        )

        guard case .metadata(let mapped)? = events.first else {
            Issue.record("Expected one mapped metadata group")
            return
        }
        #expect(mapped.items.count == 1)
        #expect(mapped.didTruncateItems)
    }

    @Test("requested value types fail closed")
    func requestedValueTypesFailClosed() async {
        let text = metadataItem(
            identifier: .id3MetadataTitleDescription,
            value: NSString(string: "not a finite number")
        )
        let group = AVTimedMetadataGroup(
            items: [text],
            timeRange: .zero
        )
        let configuration = HLSTimedMetadataConfiguration.advanced(
            fields: [.number(.id3Title)]
        )

        let events = await HLSTimedMetadataMapper.map(
            [group],
            source: .asset,
            configuration: configuration
        )

        guard
            case .metadata(let mapped)? = events.first,
            let item = mapped.items.first
        else {
            Issue.record("Expected one mapped metadata item")
            return
        }
        #expect(item.value == .unavailable)
    }

    @Test("bounded subscribers retain the newest lifecycle events")
    func boundedSubscribersRetainNewestEvents() async {
        let hub = HLSTimedMetadataEventHub()
        let stream = hub.events(maximumBufferedEventCount: 2)
        hub.send(.metadata(emptyGroup(startTime: 1)))
        hub.send(.metadata(emptyGroup(startTime: 2)))
        hub.send(.sequenceFlushed)
        var iterator = stream.makeAsyncIterator()

        #expect(
            await iterator.next()
                == .metadata(emptyGroup(startTime: 2))
        )
        #expect(await iterator.next() == .sequenceFlushed)
        hub.finish()
        #expect(await iterator.next() == nil)
    }

    @Test("delegate preserves sequence-flush events")
    func delegatePreservesSequenceFlushEvents() async {
        let hub = HLSTimedMetadataEventHub()
        let configuration = HLSTimedMetadataConfiguration.safeDefaults(
            identifiers: [.id3Title]
        )
        let delegate = HLSTimedMetadataDelegate(
            configuration: configuration,
            eventHub: hub
        )
        var iterator = hub.events(
            maximumBufferedEventCount: 2
        ).makeAsyncIterator()

        delegate.outputSequenceWasFlushed(
            AVPlayerItemMetadataOutput(
                identifiers: [
                    HLSTimedMetadataIdentifier.id3Title.rawValue
                ]
            )
        )

        #expect(await iterator.next() == .sequenceFlushed)
        delegate.finish()
        #expect(await iterator.next() == nil)
    }

    @Test("delegate reports bounded callback overflow")
    func delegateReportsCallbackOverflow() async {
        let hub = HLSTimedMetadataEventHub()
        let (processingGate, processingGateContinuation) =
            AsyncStream<Void>.makeStream()
        let configuration = HLSTimedMetadataConfiguration.advanced(
            fields: [.redacted(.id3Title)],
            maximumBufferedEventCount: 1
        )
        let delegate = HLSTimedMetadataDelegate(
            configuration: configuration,
            eventHub: hub,
            beforeProcessing: {
                for await _ in processingGate {
                    break
                }
            }
        )
        var iterator = hub.events(
            maximumBufferedEventCount: 4
        ).makeAsyncIterator()
        let output = AVPlayerItemMetadataOutput(
            identifiers: [
                HLSTimedMetadataIdentifier.id3Title.rawValue
            ]
        )

        for index in 0..<32 {
            let group = AVTimedMetadataGroup(
                items: [
                    metadataItem(
                        identifier: .id3MetadataTitleDescription,
                        value: NSString(string: "title-\(index)")
                    )
                ],
                timeRange: .zero
            )
            delegate.metadataOutput(
                output,
                didOutputTimedMetadataGroups: [group],
                from: nil
            )
        }
        delegate.outputSequenceWasFlushed(output)
        processingGateContinuation.yield()
        processingGateContinuation.finish()

        var droppedCount = 0
        while let event = await iterator.next() {
            switch event {
            case .eventsDropped(let count):
                droppedCount += count
            case .sequenceFlushed:
                delegate.finish()
                #expect(droppedCount > 0)
                return
            case .metadata:
                continue
            }
        }
        delegate.finish()
        Issue.record("Expected a sequence-flush event")
    }

    @Test("monitor attaches and finishes subscribers on detach")
    @MainActor
    func monitorAttachesAndFinishesOnDetach() async throws {
        let playerItem = AVPlayerItem(url: try sourceURL())
        let originalOutputCount = playerItem.outputs.count
        let monitor = try HLSTimedMetadataMonitor(
            playerItem: playerItem,
            configuration: .safeDefaults(identifiers: [.id3Title])
        )
        var iterator = monitor.events().makeAsyncIterator()

        #expect(monitor.isAttached)
        #expect(playerItem.outputs.count == originalOutputCount + 1)

        monitor.detach()
        monitor.detach()

        #expect(!monitor.isAttached)
        #expect(playerItem.outputs.count == originalOutputCount)
        #expect(await iterator.next() == nil)
    }

    @Test("monitor rejects an empty allowlist before AVFoundation")
    @MainActor
    func monitorRejectsEmptyAllowlist() throws {
        let playerItem = AVPlayerItem(url: try sourceURL())

        #expect(throws: HLSTimedMetadataError.emptyIdentifierAllowlist) {
            try HLSTimedMetadataMonitor(
                playerItem: playerItem,
                configuration: .safeDefaults(identifiers: [])
            )
        }
        #expect(playerItem.outputs.isEmpty)
    }

    private func metadataItem(
        identifier: AVMetadataIdentifier,
        value: any NSObject & NSCopying,
        languageTag: String? = nil,
        time: TimeInterval = 0,
        duration: TimeInterval = 0
    ) -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.identifier = identifier
        item.value = value
        item.extendedLanguageTag = languageTag
        item.time = CMTime(seconds: time, preferredTimescale: 600)
        item.duration = CMTime(
            seconds: duration,
            preferredTimescale: 600
        )
        return item.copy() as? AVMetadataItem ?? item
    }

    private func emptyGroup(
        startTime: TimeInterval
    ) -> HLSTimedMetadataGroup {
        HLSTimedMetadataGroup(
            source: .asset,
            startTime: startTime,
            duration: nil,
            items: [],
            didTruncateItems: false
        )
    }

    private func sourceURL() throws -> URL {
        try #require(
            URL(string: "https://media.example/live.m3u8")
        )
    }
}
#endif
