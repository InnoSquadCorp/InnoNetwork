import Foundation

package struct TransportPolicy<Output: Sendable>: Sendable {
    package let requestEncoding: RequestEncodingPolicy
    package let responseDecoding: ResponseDecodingStrategy<Output>
    package let responseDecoder: AnyResponseDecoder<Output>

    package init(
        requestEncoding: RequestEncodingPolicy,
        responseDecoding: ResponseDecodingStrategy<Output>,
        responseDecoder: AnyResponseDecoder<Output>
    ) {
        self.requestEncoding = requestEncoding
        self.responseDecoding = responseDecoding
        self.responseDecoder = responseDecoder
    }
}
