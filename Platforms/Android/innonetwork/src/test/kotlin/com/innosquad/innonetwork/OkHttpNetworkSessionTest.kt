package com.innosquad.innonetwork

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.async
import kotlinx.coroutines.runBlocking
import mockwebserver3.MockResponse
import mockwebserver3.MockWebServer
import mockwebserver3.SocketEffect
import okhttp3.Call
import okhttp3.EventListener
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

public class OkHttpNetworkSessionTest {
    private lateinit var server: MockWebServer

    @Before
    public fun setUp(): Unit {
        server = MockWebServer()
        server.start()
    }

    @After
    public fun tearDown(): Unit {
        server.close()
    }

    @Test
    public fun dataPreservesNativeRequestAndResponseMetadata(): Unit = runBlocking {
        server.enqueue(
            MockResponse.Builder()
                .code(201)
                .addHeader("Content-Type", "text/plain; charset=utf-8")
                .body("created")
                .build(),
        )
        val request = Request.Builder()
            .url(server.url("/users"))
            .post("name=Inno".toRequestBody())
            .header("X-Request-ID", "request-1")
            .build()

        val response = OkHttpNetworkSession(OkHttpClient()).data(request)

        assertEquals(201, response.statusCode)
        assertTrue(response.isSuccessful)
        assertEquals("created", response.bodyText())
        assertEquals("/users", response.url.encodedPath)

        val recorded = server.takeRequest()
        assertEquals("POST", recorded.method)
        assertEquals("request-1", recorded.headers["X-Request-ID"])
        assertEquals("name=Inno", recorded.body?.utf8())
    }

    @Test
    public fun httpFailureRemainsAResponseUntilExplicitlyRejected(): Unit = runBlocking {
        server.enqueue(
            MockResponse.Builder()
                .code(404)
                .body("missing")
                .build(),
        )

        val response = OkHttpNetworkSession().data(
            Request.Builder().url(server.url("/missing?token=secret")).build(),
        )

        assertFalse(response.isSuccessful)
        assertEquals("missing", response.bodyText())

        val exception = assertThrows(HttpStatusException::class.java) {
            response.requireSuccessful()
        }
        assertEquals(404, exception.response.statusCode)
        assertEquals("token=secret", exception.response.url.encodedQuery)
        assertFalse(exception.message.orEmpty().contains("secret"))
    }

    @Test
    public fun dataPreservesTheFinalRequestAfterARedirect(): Unit = runBlocking {
        server.enqueue(
            MockResponse.Builder()
                .code(302)
                .addHeader("Location", "/final?server=value")
                .build(),
        )
        server.enqueue(MockResponse.Builder().body("redirected").build())

        val response = OkHttpNetworkSession().data(
            Request.Builder().url(server.url("/start?token=secret")).build(),
        )

        assertEquals("/final", response.request.url.encodedPath)
        assertEquals("server=value", response.request.url.encodedQuery)
        assertEquals(response.request.url, response.url)
        assertEquals("redirected", response.bodyText())
    }

    @Test
    public fun transportFailuresAreTypedAndRedactURLCredentials(): Unit = runBlocking {
        server.enqueue(
            MockResponse.Builder()
                .onRequestStart(SocketEffect.CloseSocket())
                .build(),
        )
        val request = Request.Builder()
            .url(server.url("/failure?token=secret"))
            .build()

        val exception = assertThrows(NetworkTransportException::class.java) {
            runBlocking { OkHttpNetworkSession().data(request) }
        }

        assertEquals(request, exception.request)
        assertTrue(exception.message.orEmpty().contains("/failure"))
        assertFalse(exception.message.orEmpty().contains("secret"))
    }

    @Test
    public fun declaredResponseLargerThanTheConfiguredCeilingIsRejected(): Unit = runBlocking {
        server.enqueue(
            MockResponse.Builder()
                .body("12345")
                .build(),
        )
        val session = OkHttpNetworkSession(
            OkHttpClient(),
            NetworkSessionConfiguration.bounded(4L),
        )

        val exception = assertThrows(ResponseBodyTooLargeException::class.java) {
            runBlocking {
                session.data(Request.Builder().url(server.url("/large")).build())
            }
        }

        assertEquals(4L, exception.limitBytes)
        assertEquals(5L, exception.declaredBytes)
    }

    @Test
    public fun chunkedResponseIsStoppedWhenObservedBytesExceedTheCeiling(): Unit = runBlocking {
        server.enqueue(
            MockResponse.Builder()
                .chunkedBody("12345", 2)
                .build(),
        )
        val session = OkHttpNetworkSession(
            OkHttpClient(),
            NetworkSessionConfiguration.bounded(4L),
        )

        val exception = assertThrows(ResponseBodyTooLargeException::class.java) {
            runBlocking {
                session.data(Request.Builder().url(server.url("/chunked")).build())
            }
        }

        assertEquals(null, exception.declaredBytes)
        assertEquals(5L, exception.receivedBytes)
    }

    @Test
    public fun openReturnsACallerOwnedNativeStreamingResponse(): Unit = runBlocking {
        server.enqueue(
            MockResponse.Builder()
                .chunkedBody("first\nsecond\n", 3)
                .build(),
        )
        val session = OkHttpNetworkSession(OkHttpClient())
        val request = Request.Builder().url(server.url("/events")).build()

        session.open(request).use { response ->
            assertTrue(response.isSuccessful)
            assertEquals(request.url, response.response.request.url)
            assertEquals("first", response.source.readUtf8Line())
            assertEquals("second", response.source.readUtf8Line())
        }
    }

    @Test
    public fun cancellingOpenWhileAwaitingHeadersCancelsTheOkHttpCall(): Unit = runBlocking {
        server.enqueue(
            MockResponse.Builder()
                .headersDelay(5L, TimeUnit.SECONDS)
                .body("late")
                .build(),
        )
        val client = OkHttpClient()
        val session = OkHttpNetworkSession(client)
        val request = Request.Builder().url(server.url("/slow-stream")).build()

        val operation = async(start = CoroutineStart.UNDISPATCHED) { session.open(request) }
        server.takeRequest()
        operation.cancel()

        assertThrows(CancellationException::class.java) {
            runBlocking {
                operation.await()
            }
        }
        assertTrue(operation.isCancelled)
        client.dispatcher.cancelAll()
        client.connectionPool.evictAll()
        client.dispatcher.executorService.shutdown()
    }

    @Test
    public fun cancellingTheCoroutineCancelsTheOkHttpCall(): Unit = runBlocking {
        server.enqueue(
            MockResponse.Builder()
                .headersDelay(5L, TimeUnit.SECONDS)
                .body("late")
                .build(),
        )
        val client = OkHttpClient()
        val session = OkHttpNetworkSession(client)
        val request = Request.Builder().url(server.url("/slow")).build()

        val operation = async(start = CoroutineStart.UNDISPATCHED) { session.data(request) }
        server.takeRequest()
        operation.cancel()

        assertThrows(CancellationException::class.java) {
            runBlocking {
                operation.await()
            }
        }
        assertTrue(operation.isCancelled)
        client.dispatcher.cancelAll()
        client.connectionPool.evictAll()
        client.dispatcher.executorService.shutdown()
    }

    @Test
    public fun cancellingWhileBufferingTheBodyCancelsTheOkHttpCall(): Unit = runBlocking {
        server.enqueue(
            MockResponse.Builder()
                .bodyDelay(5L, TimeUnit.SECONDS)
                .body("late")
                .build(),
        )
        val headersReceived = CountDownLatch(1)
        val client = OkHttpClient.Builder()
            .eventListener(
                object : EventListener() {
                    override fun responseHeadersEnd(call: Call, response: Response): Unit {
                        headersReceived.countDown()
                    }
                },
            )
            .build()
        val session = OkHttpNetworkSession(client)
        val request = Request.Builder().url(server.url("/slow-body")).build()

        val operation = async(start = CoroutineStart.UNDISPATCHED) { session.data(request) }
        assertTrue(headersReceived.await(2L, TimeUnit.SECONDS))
        operation.cancel()

        assertThrows(CancellationException::class.java) {
            runBlocking { operation.await() }
        }
        assertTrue(operation.isCancelled)
        client.dispatcher.cancelAll()
        client.connectionPool.evictAll()
        client.dispatcher.executorService.shutdown()
    }
}
