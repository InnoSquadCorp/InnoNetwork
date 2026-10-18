package com.innosquad.innonetwork

import java.io.IOException
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.cancel
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.supervisorScope
import okhttp3.Call
import okhttp3.Callback
import okhttp3.MediaType
import okhttp3.OkHttpClient
import okhttp3.Protocol
import okhttp3.Request
import okhttp3.Response
import okhttp3.ResponseBody
import okio.Buffer
import okio.BufferedSource
import okio.Source
import okio.Timeout
import okio.buffer
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

/** Deterministic callback, resource ownership, and cancellation-race coverage. */
public class CallbackBoundaryTest {
    @Test
    public fun customBodyReadFailureReachesTheSuspendedCaller(): Unit = runBlocking {
        supervisorScope {
            val call = ControlledCall()
            val failure = IllegalStateException("custom body failure")
            val body = TrackingBody(readFailure = failure)
            val operation = async(start = CoroutineStart.UNDISPATCHED) {
                OkHttpNetworkSession(Call.Factory { call }).data(call.request())
            }
            try {
                val callbackFailure = runCatching { call.respond(body) }.exceptionOrNull()

                assertNull("Callback exceptions must settle the suspended caller", callbackFailure)
                val received = assertThrows(IllegalStateException::class.java) {
                    runBlocking { operation.await() }
                }
                // Coroutine stack recovery may copy exceptions with the original as their cause.
                assertEquals(failure.message, received.message)
                assertTrue(body.closed)
            } finally {
                operation.cancel()
            }
        }
    }

    @Test
    public fun customBodyCloseFailureReachesTheCallerInsteadOfEscapingTheCallback(): Unit = runBlocking {
        supervisorScope {
            val call = ControlledCall()
            val failure = IllegalStateException("custom close failure")
            val body = TrackingBody(closeFailure = failure)
            val operation = async(start = CoroutineStart.UNDISPATCHED) {
                OkHttpNetworkSession(Call.Factory { call }).data(call.request())
            }
            try {
                assertNull(runCatching { call.respond(body) }.exceptionOrNull())
                val received = assertThrows(IllegalStateException::class.java) {
                    runBlocking { operation.await() }
                }
                assertEquals(failure.message, received.message)
                assertTrue(body.closed)
            } finally {
                operation.cancel()
            }
        }
    }

    @Test
    public fun bufferedBodyIsClosedBeforeTheCallerResumes(): Unit = runBlocking {
        supervisorScope {
            val call = ControlledCall()
            val body = TrackingBody()
            val operation = async(Dispatchers.Unconfined, start = CoroutineStart.UNDISPATCHED) {
                val result = OkHttpNetworkSession(Call.Factory { call }).data(call.request())
                assertTrue("Body must be closed before data() returns", body.closed)
                result
            }

            call.respond(body)

            assertEquals("ok", operation.await().bodyText())
        }
    }

    @Test
    public fun cancelledBufferedCallClosesALateResponseWithoutReadingIt(): Unit = runBlocking {
        val call = ControlledCall()
        val body = TrackingBody()
        val operation = async(start = CoroutineStart.UNDISPATCHED) {
            OkHttpNetworkSession(Call.Factory { call }).data(call.request())
        }
        operation.cancel()

        call.respond(body)

        assertTrue(call.isCanceled())
        assertTrue(body.closed)
        assertEquals(0, body.reads)
        assertThrows(CancellationException::class.java) { runBlocking { operation.await() } }
    }

    @Test
    public fun cancellationBetweenStreamingResumeAndDeliveryClosesTheOwnedResponse(): Unit = runBlocking {
        val call = ControlledCall()
        val body = TrackingBody()
        val operation = async(start = CoroutineStart.UNDISPATCHED) {
            OkHttpNetworkSession(Call.Factory { call }).open(call.request())
        }
        call.respond(body)
        operation.cancel()

        assertThrows(CancellationException::class.java) { runBlocking { operation.await() } }
        assertTrue(call.isCanceled())
        assertTrue(body.closed)
        assertEquals(0, body.reads)
    }

    @Test
    public fun preCancelledOperationsDoNotCreateOrEnqueueNativeCalls(): Unit = runBlocking {
        for (streaming in listOf(false, true)) {
            var creations = 0
            val call = ControlledCall()
            val session = OkHttpNetworkSession(Call.Factory { creations += 1; call })
            val operation = async(start = CoroutineStart.UNDISPATCHED) {
                currentCoroutineContext().cancel()
                if (streaming) session.open(call.request()) else session.data(call.request())
            }

            assertThrows(CancellationException::class.java) { runBlocking { operation.await() } }
            assertEquals(0, creations)
        }
    }

    @Test
    public fun synchronousEnqueueFailurePropagatesWithoutStartingAnotherCall(): Unit = runBlocking {
        val failure = IllegalStateException("enqueue failed")
        val call = ControlledCall(enqueueFailure = failure)
        val session = OkHttpNetworkSession(Call.Factory { call })

        val received = assertThrows(IllegalStateException::class.java) {
            runBlocking { session.data(call.request()) }
        }

        assertSame(failure, received)
        assertTrue(call.isExecuted())
    }

    private class ControlledCall(
        private val enqueueFailure: RuntimeException? = null,
        private val delegate: Call = OkHttpClient().newCall(
            Request.Builder().url("https://example.com/data").build(),
        ),
    ) : Call by delegate {
        private val nativeRequest = delegate.request()
        private lateinit var callback: Callback
        private var cancelled = false
        private var executed = false

        override fun request(): Request = nativeRequest
        override fun execute(): Response = throw IOException("Synchronous execution is not used")
        override fun enqueue(responseCallback: Callback) {
            executed = true
            enqueueFailure?.let { throw it }
            callback = responseCallback
        }
        override fun cancel() { cancelled = true }
        override fun isExecuted(): Boolean = executed
        override fun isCanceled(): Boolean = cancelled
        override fun timeout(): Timeout = Timeout.NONE
        override fun clone(): Call = ControlledCall(enqueueFailure)

        fun respond(body: ResponseBody) {
            callback.onResponse(this, Response.Builder()
                .request(nativeRequest)
                .protocol(Protocol.HTTP_1_1)
                .code(200)
                .message("OK")
                .body(body)
                .build())
        }
    }

    private class TrackingBody(
        readFailure: RuntimeException? = null,
        closeFailure: RuntimeException? = null,
    ) : ResponseBody() {
        var closed: Boolean = false
        var reads: Int = 0
        private val bytes = Buffer().writeUtf8("ok")
        private val bufferedSource = object : Source {
            override fun read(sink: Buffer, byteCount: Long): Long {
                reads += 1
                readFailure?.let { throw it }
                return bytes.read(sink, byteCount)
            }
            override fun timeout(): Timeout = Timeout.NONE
            override fun close() {
                closed = true
                closeFailure?.let { throw it }
            }
        }.buffer()

        override fun contentType(): MediaType? = null
        override fun contentLength(): Long = -1L
        override fun source(): BufferedSource = bufferedSource
    }
}
