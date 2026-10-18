package com.innosquad.innonetwork

import java.io.IOException
import okhttp3.HttpUrl
import okhttp3.Request

/** A failure reported by the HTTP transport before a complete response was buffered. */
public class NetworkTransportException(
    /** Request associated with the failure. */
    public val request: Request,
    cause: IOException,
) : IOException("Transport failed for ${request.url.safeForMessage()}", cause)

/** A buffered response exceeded the configured session ceiling. */
public class ResponseBodyTooLargeException(
    /** Response URL. */
    public val url: HttpUrl,
    /** Configured response ceiling. */
    public val limitBytes: Long,
    /** Content-Length supplied by the server, or `null` when absent or unknown. */
    public val declaredBytes: Long?,
    /** Bytes observed before buffering stopped. */
    public val receivedBytes: Long,
) : IOException("Response body from ${url.safeForMessage()} exceeded $limitBytes bytes")

/** A non-2xx response explicitly rejected by [NetworkDataResponse.requireSuccessful]. */
public class HttpStatusException(
    /** The complete response, including its bounded body. */
    public val response: NetworkDataResponse,
) : IOException("HTTP ${response.statusCode} for ${response.url.safeForMessage()}")

/** A buffered response could not be decoded by the selected endpoint or serializer. */
public class NetworkDecodingException(
    /** The response whose body failed validation or decoding. */
    public val response: NetworkDataResponse,
    cause: Throwable,
) : IllegalArgumentException("Failed to decode response from ${response.url.safeForMessage()}", cause)

private fun HttpUrl.safeForMessage(): String {
    val messageHost = if (':' in host) "[$host]" else host
    val usesDefaultPort = (scheme == "http" && port == 80) || (scheme == "https" && port == 443)
    val messagePort = if (usesDefaultPort) "" else ":$port"
    return "$scheme://$messageHost$messagePort$encodedPath"
}
