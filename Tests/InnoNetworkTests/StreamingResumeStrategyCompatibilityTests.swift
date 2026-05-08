import Foundation
import Testing

@testable import InnoNetwork

@Suite("Streaming resume strategy compatibility")
struct StreamingResumeStrategyCompatibilityTests {
    @Test(".disabled is compatible with every buffering policy")
    func disabledCompatibleWithAll() async {
        let policy = StreamingResumePolicy.disabled
        #expect(policy.isCompatible(with: .unbounded))
        #expect(policy.isCompatible(with: .bufferingNewest(10)))
        #expect(policy.isCompatible(with: .bufferingOldest(10)))
    }

    @Test(".lastEventID rejects bounded buffering policies")
    func lastEventIDRejectsBounded() async {
        let policy = StreamingResumePolicy.lastEventID(maxAttempts: 3)
        #expect(policy.isCompatible(with: .unbounded))
        #expect(!policy.isCompatible(with: .bufferingNewest(50)))
        #expect(!policy.isCompatible(with: .bufferingOldest(50)))
    }

    @Test("StreamingBufferingPolicy.maySilentlyDropOutputs is true only for bounded variants")
    func bufferingPolicyDropFlag() async {
        #expect(!StreamingBufferingPolicy.unbounded.maySilentlyDropOutputs)
        #expect(StreamingBufferingPolicy.bufferingNewest(1).maySilentlyDropOutputs)
        #expect(StreamingBufferingPolicy.bufferingOldest(1).maySilentlyDropOutputs)
    }
}
