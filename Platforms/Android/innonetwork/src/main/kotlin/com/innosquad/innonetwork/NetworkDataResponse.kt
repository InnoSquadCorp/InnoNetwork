package com.innosquad.innonetwork

import java.nio.charset.Charset
import okhttp3.Headers
import okhttp3.HttpUrl
import okhttp3.MediaType
import okhttp3.Protocol
import okhttp3.Request
import okio.ByteString

/** Immutable metadata and buffered bytes produced by [NetworkSession.data]. */
public class NetworkDataResponse(
    /** The final request after redirects and OkHttp interceptors. */
    public val request: Request,
    /** The final response URL. */
    public val url: HttpUrl,
    /** HTTP status code. HTTP failures are values, not transport exceptions. */
    public val statusCode: Int,
    /** HTTP status message supplied by the transport. */
    public val statusMessage: String,
    /** Response headers. */
    public val headers: Headers,
    /** Negotiated HTTP protocol. */
    public val protocol: Protocol,
    /** Parsed response media type when supplied by the server. */
    public val contentType: MediaType?,
    /** Request-send timestamp reported by OkHttp. */
    public val sentRequestAtMillis: Long,
    /** Response-receive timestamp reported by OkHttp. */
    public val receivedResponseAtMillis: Long,
    /** Immutable buffered response body. */
    public val body: ByteString,
) {
    /** Whether [statusCode] is in the inclusive 200...299 range. */
    public val isSuccessful: Boolean
        get() = statusCode in 200..299

    /** Decodes the body using the charset declared by Content-Type, falling back to UTF-8. */
    public fun bodyText(): String = body.string(contentType?.charset(Charsets.UTF_8) ?: Charsets.UTF_8)

    /** Decodes the body using an explicit [charset]. */
    public fun bodyText(charset: Charset): String = body.string(charset)

    /** Returns this response or throws [HttpStatusException] for a non-2xx status. */
    public fun requireSuccessful(): NetworkDataResponse {
        if (!isSuccessful) {
            throw HttpStatusException(this)
        }
        return this
    }
}
