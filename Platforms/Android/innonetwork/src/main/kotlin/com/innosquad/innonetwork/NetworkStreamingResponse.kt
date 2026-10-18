package com.innosquad.innonetwork

import java.io.Closeable
import okhttp3.Call
import okhttp3.Response
import okio.BufferedSource

/**
 * Caller-owned native OkHttp response returned by [StreamingNetworkSession.open].
 *
 * Read [source] on a dispatcher suitable for blocking I/O. Closing this value releases the
 * response body. [cancel] additionally cancels the underlying OkHttp call.
 */
public class NetworkStreamingResponse internal constructor(
    private val call: Call,
    /** Native response metadata and body. */
    public val response: Response,
) : Closeable {
    /** Native buffered source for the response body. */
    public val source: BufferedSource
        get() = response.body.source()

    /** Whether the native response status is in the inclusive 200...299 range. */
    public val isSuccessful: Boolean
        get() = response.isSuccessful

    /** Cancels the active call and closes the response body. */
    public fun cancel(): Unit {
        call.cancel()
        response.close()
    }

    /** Closes the response body without changing the call's completed/cancelled state. */
    override fun close(): Unit = response.close()
}
