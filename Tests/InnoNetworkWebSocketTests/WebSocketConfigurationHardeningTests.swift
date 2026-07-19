import Foundation
import InnoNetworkTestSupport
import Testing
import os

@testable import InnoNetwork
@testable import InnoNetworkWebSocket

@Suite("WebSocket Configuration Hardening Tests")
struct WebSocketConfigurationHardeningTests {

    @Test("maximumMessageSize is clamped to at least 1 byte")
    func maximumMessageSizeClampedToOne() {
        let config = WebSocketConfiguration(maximumMessageSize: 0)
        #expect(config.maximumMessageSize == 1)

        let negativeConfig = WebSocketConfiguration(maximumMessageSize: -1024)
        #expect(negativeConfig.maximumMessageSize == 1)
    }

    @Test("reconnectMaxTotalDuration negative values are clamped to zero (disabled)")
    func reconnectMaxTotalDurationClamped() {
        let config = WebSocketConfiguration(reconnectMaxTotalDuration: -10)
        #expect(config.reconnectMaxTotalDuration == 0)
    }

    @Test("permessageDeflateEnabled defaults to false (URLSession does not advertise it)")
    func permessageDeflateDefaultsFalse() {
        let config = WebSocketConfiguration()
        #expect(config.permessageDeflateEnabled == false)
    }

    @Test("Advanced packs roundtrip hardening fields without loss")
    func advancedPacksRoundtripHardeningFields() {
        let config = WebSocketConfiguration.advanced(
            reconnect: WebSocketReconnectPack(maxTotalDuration: 90),
            messaging: WebSocketMessagingPack(
                maximumMessageSize: 8 * 1024 * 1024,
                permessageDeflateEnabled: true
            )
        )
        #expect(config.maximumMessageSize == 8 * 1024 * 1024)
        #expect(config.permessageDeflateEnabled == true)
        #expect(config.reconnectMaxTotalDuration == 90)
    }
}
