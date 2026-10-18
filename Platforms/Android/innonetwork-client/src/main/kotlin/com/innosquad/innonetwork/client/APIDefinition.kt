package com.innosquad.innonetwork.client

import com.innosquad.innonetwork.NetworkDataResponse
import okhttp3.HttpUrl
import okhttp3.Request

/**
 * Typed request/response definition executed by [NetworkClient].
 *
 * Implementations and KSP-generated definitions build a native OkHttp [Request]. The
 * transport remains visible and configurable instead of being mirrored as an annotation runtime.
 */
public interface APIDefinition<Response> {
    /** Builds the native request for one execution attempt against [baseUrl]. */
    public fun request(baseUrl: HttpUrl): Request

    /** Returns whether [statusCode] may be decoded as this endpoint's successful response. */
    public fun acceptsStatusCode(statusCode: Int): Boolean = statusCode in 200..299

    /** Decodes the already bounded response into the endpoint's output type. */
    public fun decode(response: NetworkDataResponse): Response
}
