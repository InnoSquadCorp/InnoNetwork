package com.innosquad.innonetwork

import java.io.IOException
import kotlinx.coroutines.CancellableContinuation
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.suspendCancellableCoroutine
import okhttp3.Call
import okhttp3.Callback
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okio.Buffer
import okio.ByteString

/**
 * A [NetworkSession] backed directly by OkHttp.
 *
 * Callers continue to build native [Request] values and configure interceptors, TLS, caching,
 * cookies, connection pooling, and observability on their [OkHttpClient]. InnoNetwork owns only
 * coroutine cancellation, typed transport errors, and bounded response buffering.
 */
public class OkHttpNetworkSession public constructor(
    private val callFactory: Call.Factory,
    private val configuration: NetworkSessionConfiguration,
) : NetworkSession, StreamingNetworkSession {
    /** Creates a session with a new [OkHttpClient] and safe buffering defaults. */
    public constructor() : this(OkHttpClient(), NetworkSessionConfiguration.safeDefaults())

    /** Creates a session with the supplied OkHttp [callFactory] and safe buffering defaults. */
    public constructor(callFactory: Call.Factory) :
        this(callFactory, NetworkSessionConfiguration.safeDefaults())

    override suspend fun data(request: Request): NetworkDataResponse {
        currentCoroutineContext().ensureActive()
        return suspendCancellableCoroutine { continuation ->
            val call = callFactory.newCall(request)
            continuation.invokeOnCancellation { call.cancel() }
            if (continuation.isActive) {
                call.enqueue(ResponseCallback(request, configuration, continuation))
            }
        }
    }

    override suspend fun open(request: Request): NetworkStreamingResponse {
        currentCoroutineContext().ensureActive()
        return suspendCancellableCoroutine { continuation ->
            val call = callFactory.newCall(request)
            continuation.invokeOnCancellation { call.cancel() }
            if (continuation.isActive) {
                call.enqueue(OpenResponseCallback(request, continuation))
            }
        }
    }

    private class ResponseCallback(
        private val originalRequest: Request,
        private val configuration: NetworkSessionConfiguration,
        private val continuation: CancellableContinuation<NetworkDataResponse>,
    ) : Callback {
        override fun onFailure(call: Call, e: IOException) {
            if (!continuation.isActive) {
                return
            }
            continuation.completeFailure(NetworkTransportException(originalRequest, e))
        }

        override fun onResponse(call: Call, response: Response) {
            try {
                val result = response.use { openResponse ->
                    if (!continuation.isActive) {
                        return
                    }
                    openResponse.toNetworkDataResponse(configuration)
                }
                continuation.completeSuccess(result)
            } catch (exception: ResponseBodyTooLargeException) {
                continuation.completeFailure(exception)
            } catch (exception: IOException) {
                continuation.completeFailure(NetworkTransportException(response.request, exception))
            } catch (exception: Exception) {
                // User-provided bodies/interceptors may fail outside IOException. Deliver their
                // failure to the suspended caller instead of escaping OkHttp's callback thread.
                continuation.completeFailure(exception)
            }
        }
    }

    private class OpenResponseCallback(
        private val originalRequest: Request,
        private val continuation: CancellableContinuation<NetworkStreamingResponse>,
    ) : Callback {
        override fun onFailure(call: Call, e: IOException) {
            if (!continuation.isActive) {
                return
            }
            continuation.completeOpenFailure(NetworkTransportException(originalRequest, e))
        }

        override fun onResponse(call: Call, response: Response) {
            val streamingResponse = NetworkStreamingResponse(call, response)
            if (!continuation.isActive) {
                streamingResponse.close()
                return
            }
            continuation.resume(streamingResponse) { _, cancelledResponse, _ ->
                cancelledResponse.cancel()
            }
        }
    }
}

private fun Response.toNetworkDataResponse(
    configuration: NetworkSessionConfiguration,
): NetworkDataResponse {
    val responseBody = body
    val bufferedBody = responseBody.readBounded(
        url = request.url,
        maxResponseBodyBytes = configuration.maxResponseBodyBytes,
    )

    return NetworkDataResponse(
        request = request,
        url = request.url,
        statusCode = code,
        statusMessage = message,
        headers = headers,
        protocol = protocol,
        contentType = responseBody.contentType(),
        sentRequestAtMillis = sentRequestAtMillis,
        receivedResponseAtMillis = receivedResponseAtMillis,
        body = bufferedBody,
    )
}

private fun okhttp3.ResponseBody.readBounded(
    url: okhttp3.HttpUrl,
    maxResponseBodyBytes: Long?,
): ByteString {
    val declaredBytes = contentLength().takeIf { it >= 0L }
    if (maxResponseBodyBytes != null && declaredBytes != null && declaredBytes > maxResponseBodyBytes) {
        throw ResponseBodyTooLargeException(
            url = url,
            limitBytes = maxResponseBodyBytes,
            declaredBytes = declaredBytes,
            receivedBytes = 0L,
        )
    }

    val source = source()
    val buffer = Buffer()
    var receivedBytes = 0L

    while (true) {
        val readSize = when (maxResponseBodyBytes) {
            null -> READ_CHUNK_BYTES
            else -> {
                val remainingBytes = maxResponseBodyBytes - receivedBytes
                if (remainingBytes >= READ_CHUNK_BYTES) {
                    READ_CHUNK_BYTES
                } else {
                    remainingBytes + 1L
                }
            }
        }
        val readBytes = source.read(buffer, readSize)
        if (readBytes == -1L) {
            break
        }
        receivedBytes += readBytes
        if (maxResponseBodyBytes != null && receivedBytes > maxResponseBodyBytes) {
            throw ResponseBodyTooLargeException(
                url = url,
                limitBytes = maxResponseBodyBytes,
                declaredBytes = declaredBytes,
                receivedBytes = receivedBytes,
            )
        }
    }

    return buffer.readByteString()
}

private fun CancellableContinuation<NetworkDataResponse>.completeSuccess(
    response: NetworkDataResponse,
) {
    if (isActive) {
        resumeWith(Result.success(response))
    }
}

private fun CancellableContinuation<NetworkDataResponse>.completeFailure(exception: Throwable) {
    if (isActive) {
        resumeWith(Result.failure(exception))
    }
}

private fun CancellableContinuation<NetworkStreamingResponse>.completeOpenFailure(exception: Throwable) {
    if (isActive) {
        resumeWith(Result.failure(exception))
    }
}

private const val READ_CHUNK_BYTES: Long = 8L * 1024L
