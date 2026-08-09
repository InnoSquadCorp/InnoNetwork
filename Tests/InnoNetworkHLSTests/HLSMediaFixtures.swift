import Foundation
import Testing

enum HLSMediaFixtures {
    static let transportStreamPlaylist = """
        #EXTM3U
        #EXT-X-VERSION:3
        #EXT-X-TARGETDURATION:1
        #EXT-X-MEDIA-SEQUENCE:0
        #EXT-X-PLAYLIST-TYPE:VOD
        #EXTINF:1.000000,
        segment-0.ts
        #EXT-X-ENDLIST

        """

    static let fragmentedMP4Playlist = """
        #EXTM3U
        #EXT-X-VERSION:7
        #EXT-X-TARGETDURATION:1
        #EXT-X-MEDIA-SEQUENCE:0
        #EXT-X-PLAYLIST-TYPE:VOD
        #EXT-X-MAP:URI="init.mp4"
        #EXTINF:1.000000,
        segment-0.m4s
        #EXTINF:1.000000,
        segment-1.m4s
        #EXT-X-ENDLIST

        """

    static func fragmentedMP4Initialization() throws -> Data {
        try decode(fragmentedMP4InitializationBase64)
    }

    static func fragmentedMP4Segment0() throws -> Data {
        try decode(fragmentedMP4Segment0Base64)
    }

    static func fragmentedMP4Segment1() throws -> Data {
        try decode(fragmentedMP4Segment1Base64)
    }

    static func transportStreamSegment0() throws -> Data {
        try decode(transportStreamSegment0Base64)
    }

    private static func decode(_ value: String) throws -> Data {
        try #require(
            Data(
                base64Encoded: value,
                options: .ignoreUnknownCharacters
            )
        )
    }

    // Generated from a two-second 64x64 H.264 VOD asset. Keeping the small
    // fixture inline avoids a runtime dependency on ffmpeg in consumer CI.
    private static let fragmentedMP4InitializationBase64 = """
        AAAAHGZ0eXBpc281AAACAGlzbzVpc282bXA0MQAAAx5tb292AAAAbG12aGQAAAAAAAAAAAAAAAAAAAPoAAAAAAABAAABAAAAAAAAAAAAAAAAAQAAAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAACAAACIHRyYWsAAABcdGtoZAAAAAMAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAQAAAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAEAAAAAAQAAAAEAAAAAAADBlZHRzAAAAKGVsc3QAAAAAAAAAAgAAAFP/////AAEAAAAAAAAAAAQAAAEAAAAAAYxtZGlhAAAAIG1kaGQAAAAAAAAAAAAAAAAAADAAAAAAAFXEAAAAAAAtaGRscgAAAAAAAAAAdmlkZQAAAAAAAAAAAAAAAFZpZGVvSGFuZGxlcgAAAAE3bWluZgAAABR2bWhkAAAAAQAAAAAAAAAAAAAAJGRpbmYAAAAcZHJlZgAAAAAAAAABAAAADHVybCAAAAABAAAA93N0YmwAAACrc3RzZAAAAAAAAAABAAAAm2F2YzEAAAAAAAAAAQAAAAAAAAAAAAAAAAAAAAAAQABAAEgAAABIAAAAAAAAAAEVTGF2YzYyLjI4LjEwMiBsaWJ4MjY0AAAAAAAAAAAAAAAY//8AAAA1YXZjQwFkAAr/4QAYZ2QACqzZRCbARAAAAwAEAAADAMA8SJZYAQAGaOvjyyLA/fj4AAAAABBwYXNwAAAAAQAAAAEAAAAQc3R0cwAAAAAAAAAAAAAAEHN0c2MAAAAAAAAAAAAAABRzdHN6AAAAAAAAAAAAAAAAAAAAEHN0Y28AAAAAAAAAAAAAAChtdmV4AAAAIHRyZXgAAAAAAAAAAQAAAAEAAAAAAAAAAAAAAAAAAABidWR0YQAAAFptZXRhAAAAAAAAACFoZGxyAAAAAAAAAABtZGlyYXBwbAAAAAAAAAAAAAAAAC1pbHN0AAAAJal0b28AAAAdZGF0YQAAAAEAAAAATGF2ZjYyLjEyLjEwMg==
        """

    private static let fragmentedMP4Segment0Base64 = """
        AAAAGHN0eXBtc2RoAAAAAG1zZGhtc2l4AAAANHNpZHgBAAAAAAAAAQAAMAAAAAAAAAAEAAAAAAAAAAAAAAAAAQAABUwAADAAgAAAAAAAAShtb29mAAAAEG1maGQAAAAAAAAAAQAAARB0cmFmAAAAHHRmaGQAAgA4AAAAAQAAAgAAAALUAQEAAAAAABR0ZmR0AQAAAAAAAAAAAAAAAAAA2HRydW4AAAoFAAAAGAAAATACAAAAAAAC1AAABAAAAAAOAAAKAAAAAAwAAAQAAAAADAAAAAAAAAAMAAACAAAAABQAAAoAAAAADgAABAAAAAAMAAAAAAAAAAwAAAIAAAAAFAAACgAAAAAOAAAEAAAAAAwAAAAAAAAADAAAAgAAAAAUAAAKAAAAAA4AAAQAAAAADAAAAAAAAAAMAAACAAAAABQAAAoAAAAADgAABAAAAAAMAAAAAAAAAAwAAAIAAAAAFAAACAAAAAAOAAACAAAAAAwAAAIAAAAEJG1kYXQAAAKsBgX//6jcRem95tlIt5Ys2CDZI+7veDI2NCAtIGNvcmUgMTY1IHIzMjIyIGIzNTYwNWEgLSBILjI2NC9NUEVHLTQgQVZDIGNvZGVjIC0gQ29weWxlZnQgMjAwMy0yMDI1IC0gaHR0cDovL3d3dy52aWRlb2xhbi5vcmcveDI2NC5odG1sIC0gb3B0aW9uczogY2FiYWM9MSByZWY9MyBkZWJsb2NrPTE6MDowIGFuYWx5c2U9MHgzOjB4MTEzIG1lPWhleCBzdWJtZT03IHBzeT0xIHBzeV9yZD0xLjAwOjAuMDAgbWl4ZWRfcmVmPTEgbWVfcmFuZ2U9MTYgY2hyb21hX21lPTEgdHJlbGxpcz0xIDh4OGRjdD0xIGNxbT0wIGRlYWR6b25lPTIxLDExIGZhc3RfcHNraXA9MSBjaHJvbWFfcXBfb2Zmc2V0PS0yIHRocmVhZHM9MiBsb29rYWhlYWRfdGhyZWFkcz0xIHNsaWNlZF90aHJlYWRzPTAgbnI9MCBkZWNpbWF0ZT0xIGludGVybGFjZWQ9MCBibHVyYXlfY29tcGF0PTAgY29uc3RyYWluZWRfaW50cmE9MCBiZnJhbWVzPTMgYl9weXJhbWlkPTIgYl9hZGFwdD0xIGJfYmlhcz0wIGRpcmVjdD0xIHdlaWdodGI9MSBvcGVuX2dvcD0wIHdlaWdodHA9MiBrZXlpbnQ9MjQga2V5aW50X21pbj0xMyBzY2VuZWN1dD0wIGludHJhX3JlZnJlc2g9MCByY19sb29rYWhlYWQ9MjQgcmM9Y3JmIG1idHJlZT0xIGNyZj0yMy4wIHFjb21wPTAuNjAgcXBtaW49MCBxcG1heD02OSBxcHN0ZXA9NCBpcF9yYXRpbz0xLjQwIGFxPTE6MS4wMACAAAAAIGWIhAA7//73Tr8Cm1TCKgOSVwrqg7oK2KdPKm0Gjfu5AAAACkGaJGxDv/6pnTQAAAAIQZ5CeIX/CbkAAAAIAZ5hdEK/DDgAAAAIAZ5jakK/DDkAAAAQQZpoSahBaJlMCHf//qmdNQAAAApBnoZFESwv/wm5AAAACAGepXRCvww5AAAACAGep2pCvww4AAAAEEGarEmoQWyZTAh3//6pnTQAAAAKQZ7KRRUsL/8JuQAAAAgBnul0Qr8MOAAAAAgBnutqQr8MOAAAABBBmvBJqEFsmUwId//+qZ01AAAACkGfDkUVLC//CbkAAAAIAZ8tdEK/DDkAAAAIAZ8vakK/DDgAAAAQQZs0SahBbJlMCHf//qmdNAAAAApBn1JFFSwv/wm5AAAACAGfcXRCvww4AAAACAGfc2pCvww4AAAAEEGbd0moQWyZTAhX//44jcEAAAAKQZ+VRRUsK/8MOAAAAAgBn7ZqQr8MOQ==
        """

    private static let fragmentedMP4Segment1Base64 = """
        AAAAGHN0eXBtc2RoAAAAAG1zZGhtc2l4AAAANHNpZHgBAAAAAAAAAQAAMAAAAAAAAAA0AAAAAAAAAAAAAAAAAQAAAp0AADAAgAAAAAAAAShtb29mAAAAEG1maGQAAAAAAAAAAgAAARB0cmFmAAAAHHRmaGQAAgA4AAAAAQAAAgAAAAAlAQEAAAAAABR0ZmR0AQAAAAAAAAAAADAAAAAA2HRydW4AAAoFAAAAGAAAATACAAAAAAAAJQAABAAAAAAOAAAKAAAAAAwAAAQAAAAADAAAAAAAAAAMAAACAAAAABQAAAoAAAAADgAABAAAAAAMAAAAAAAAAAwAAAIAAAAAFAAACgAAAAAOAAAEAAAAAAwAAAAAAAAADAAAAgAAAAAUAAAKAAAAAA4AAAQAAAAADAAAAAAAAAAMAAACAAAAABQAAAoAAAAADgAABAAAAAAMAAAAAAAAAAwAAAIAAAAAFAAACAAAAAAOAAACAAAAAAwAAAIAAAABdW1kYXQAAAAhZYiCAAR//veIHzLLb5xq13IR56xU/UYjGW1z52a6GKd5AAAACkGaJGxDv/6pnTQAAAAIQZ5CeIX/CbkAAAAIAZ5hdEK/DDgAAAAIAZ5jakK/DDkAAAAQQZpoSahBaJlMCHf//qmdNQAAAApBnoZFESwv/wm4AAAACAGepXRCvww4AAAACAGep2pCvww5AAAAEEGarEmoQWyZTAh3//6pnTQAAAAKQZ7KRRUsL/8JuQAAAAgBnul0Qr8MOAAAAAgBnutqQr8MOQAAABBBmvBJqEFsmUwIb//+p4+JAAAACkGfDkUVLC//CbkAAAAIAZ8tdEK/DDkAAAAIAZ8vakK/DDgAAAAQQZs0SahBbJlMCGf//p4t8AAAAApBn1JFFSwv/wm5AAAACAGfcXRCvww4AAAACAGfc2pCvww4AAAAEEGbd0moQWyZTAhX//44jcEAAAAKQZ+VRRUsK/8MOQAAAAgBn7ZqQr8MOQ==
        """

    private static let transportStreamSegment0Base64 = """
        R0AREABC8CUAAcEAAP8B/wAB/IAUSBIBBkZGbXBlZwlTZXJ2aWNlMDF3fEPK//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////9HQAAQAACwDQABwQAAAAHwACqxBLL//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////0dQABAAArASAAHBAADhAPAAG+EA8AAVvU1W////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////R0EAMAdQAAB7DH4AAAAB4AAAgMAKMQAJEvkRAAfYYQAAAAEJ8AAAAAFnZAAKrNlewEQAAAMABAAAAwDAPEiWWAAAAAFo6+PLIsAAAAEGBf//qNxF6b3m2Ui3lizYINkj7u94MjY0IC0gY29yZSAxNjUgcjMyMjIgYjM1NjA1YSAtIEguMjY0L01QRUctNCBBVkMgY29kZWMgLSBDb3B5bGVmdCAyMDAzLTIwMjUgLSBodHRwOi8vd3d3LnZHAQARaWRlb2xhbi5vcmcveDI2NC5odG1sIC0gb3B0aW9uczogY2FiYWM9MSByZWY9MyBkZWJsb2NrPTE6MDowIGFuYWx5c2U9MHgzOjB4MTEzIG1lPWhleCBzdWJtZT03IHBzeT0xIHBzeV9yZD0xLjAwOjAuMDAgbWl4ZWRfcmVmPTEgbWVfcmFuZ2U9MTYgY2hyb21hX21lPTEgdHJlbGxpcz0xIDh4OGRjdD0xIGNxbT0wIGRlYWR6b0cBABJuZT0yMSwxMSBmYXN0X3Bza2lwPTEgY2hyb21hX3FwX29mZnNldD0tMiB0aHJlYWRzPTEgbG9va2FoZWFkX3RocmVhZHM9MSBzbGljZWRfdGhyZWFkcz0wIG5yPTAgZGVjaW1hdGU9MSBpbnRlcmxhY2VkPTAgYmx1cmF5X2NvbXBhdD0wIGNvbnN0cmFpbmVkX2ludHJhPTAgYmZyYW1lcz0zIGJfcHlyYW1pZD0yIGJfYWRhcHQ9RwEAEzEgYl9iaWFzPTAgZGlyZWN0PTEgd2VpZ2h0Yj0xIG9wZW5fZ29wPTAgd2VpZ2h0cD0yIGtleWludD0yNCBrZXlpbnRfbWluPTEzIHNjZW5lY3V0PTAgaW50cmFfcmVmcmVzaD0wIHJjX2xvb2thaGVhZD0yNCByYz1jcmYgbWJ0cmVlPTEgY3JmPTIzLjAgcWNvbXA9MC42MCBxcG1pbj0wIHFwbWF4PTY5IHFwc3RlcD00IGlwX3JHAQA0jwD/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////YXRpbz0xLjQwIGFxPTE6MS4wMACAAAAAAWWIhAA7//73Tr8Cm1TCYUdBADWSEAAAgl9+AP////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////8AAAHgAACAwAoxAAmIKREAB/WtAAAAAQnwAAAAAUGaJGxDv/7gR0EANpIQAACJsn4A/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////wAAAeAAAIDACjEACU2REQAJEvkAAAABCfAAAAABQZ5CeIX/wYFHQQA3lxAAAJEFfgD///////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////8AAAHgAACAgAUhAAkwRQAAAAEJ8AAAAAEBnmF0Qr/EgEdBADiSEAAAmFh+AP////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////8AAAHgAACAwAoxAAlq3REACU2RAAAAAQnwAAAAAQGeY2pCv8SBR0EAOYwQAACfq34A/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////wAAAeAAAIDACjEACf1ZEQAJat0AAAABCfAAAAABQZpoSahBaJlMCHf//uFHQQA6kBAAAKb+fgD//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////wAAAeAAAIDACjEACcLBEQAJiCkAAAABCfAAAAABQZ6GRREsL//BgUdBADuXEAAArlF+AP///////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////wAAAeAAAICABSEACaV1AAAAAQnwAAAAAQGepXRCv8SBR0EAPJIQAAC1pH4A/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////wAAAeAAAIDACjEACeANEQAJwsEAAAABCfAAAAABAZ6nakK/xIBHQQA9jBAAALz3fgD/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////AAAB4AAAgMAKMQALcokRAAngDQAAAAEJ8AAAAAFBmqxJqEFsmUwId//+4EdBAD6QEAAAxEp+AP//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////AAAB4AAAgMAKMQALN/ERAAn9WQAAAAEJ8AAAAAFBnspFFSwv/8GBR0EAP5cQAADLnX4A////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////AAAB4AAAgIAFIQALGqUAAAABCfAAAAABAZ7pdEK/xIBHQQAwkhAAANLwfgD/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////AAAB4AAAgMAKMQALVT0RAAs38QAAAAEJ8AAAAAEBnutqQr/EgEdBADGMEAAA2kN+AP////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////8AAAHgAACAwAoxAAvnuREAC1U9AAAAAQnwAAAAAUGa8EmoQWyZTAh3//7hR0EAMpAQAADhln4A//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////8AAAHgAACAwAoxAAutIREAC3KJAAAAAQnwAAAAAUGfDkUVLC//wYFHQQAzlxAAAOjpfgD///////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////8AAAHgAACAgAUhAAuP1QAAAAEJ8AAAAAEBny10Qr/EgUdBADSSEAAA8Dx+AP////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////8AAAHgAACAwAoxAAvKbREAC60hAAAAAQnwAAAAAQGfL2pCv8SAR0EANYwQAAD3j34A/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////wAAAeAAAIDACjEADVzpEQALym0AAAABCfAAAAABQZs0SahBbJlMCHf//uBHQQA2kBAAAP7ifgD//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////wAAAeAAAIDACjEADSJREQAL57kAAAABCfAAAAABQZ9SRRUsL//BgUdBADeXEAABBjV+AP///////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////wAAAeAAAICABSEADQUFAAAAAQnwAAAAAQGfcXRCv8SAR0EAOJIQAAENiH4A/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////wAAAeAAAIDACjEADT+dEQANIlEAAAABCfAAAAABAZ9zakK/xIBHQQA5jBAAARTbfgD/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////AAAB4AAAgMAKMQANtM0RAA0/nQAAAAEJ8AAAAAFBm3dJqEFsmUwIV//+wUdBADqQEAABHC5+AP//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////AAAB4AAAgMAKMQANejURAA1c6QAAAAEJ8AAAAAFBn5VFFSwr/8SAR0EAO5IQAAEjgX4A/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////wAAAeAAAIDACjEADZeBEQANejUAAAABCfAAAAABAZ+2akK/xIE=
        """
}
