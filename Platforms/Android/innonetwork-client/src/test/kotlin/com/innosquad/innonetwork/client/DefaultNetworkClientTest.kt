package com.innosquad.innonetwork.client

import com.innosquad.innonetwork.HttpStatusException
import com.innosquad.innonetwork.NetworkDataResponse
import com.innosquad.innonetwork.NetworkDecodingException
import com.innosquad.innonetwork.OkHttpNetworkSession
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.runBlocking
import mockwebserver3.MockResponse
import mockwebserver3.MockWebServer
import okhttp3.HttpUrl
import okhttp3.Request
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Before
import org.junit.Test

public class DefaultNetworkClientTest {
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
    public fun requestExecutesAndDecodesATypedNativeDefinition(): Unit = runBlocking {
        server.enqueue(MockResponse.Builder().body("hello").build())
        val client = DefaultNetworkClient(server.url("/"), OkHttpNetworkSession())
        val endpoint = TextEndpoint("message")

        val result = client.request(endpoint)

        assertEquals("hello", result)
        assertEquals("/message", server.takeRequest().url.encodedPath)
    }

    @Test
    public fun requestRejectsUnacceptedStatusBeforeDecoding(): Unit = runBlocking {
        server.enqueue(MockResponse.Builder().code(404).body("missing").build())
        val decoded = AtomicBoolean(false)
        val endpoint = object : APIDefinition<String> {
            override fun request(baseUrl: HttpUrl): Request = Request.Builder()
                .url(baseUrl.newBuilder().addPathSegment("missing").build())
                .build()

            override fun decode(response: NetworkDataResponse): String {
                decoded.set(true)
                return response.bodyText()
            }
        }

        val exception = assertThrows(HttpStatusException::class.java) {
            runBlocking {
                DefaultNetworkClient(server.url("/"), OkHttpNetworkSession()).request(endpoint)
            }
        }

        assertEquals(404, exception.response.statusCode)
        assertFalse(decoded.get())
    }

    @Test
    public fun endpointMayExplicitlyAcceptANon2xxStatus(): Unit = runBlocking {
        server.enqueue(MockResponse.Builder().code(404).body("missing").build())
        val endpoint = object : APIDefinition<String> {
            override fun request(baseUrl: HttpUrl): Request = Request.Builder()
                .url(baseUrl.newBuilder().addPathSegment("optional").build())
                .build()

            override fun acceptsStatusCode(statusCode: Int): Boolean = statusCode == 404

            override fun decode(response: NetworkDataResponse): String = response.bodyText()
        }

        val result = DefaultNetworkClient(server.url("/"), OkHttpNetworkSession()).request(endpoint)

        assertEquals("missing", result)
    }

    @Test
    public fun foreignDecoderFailuresMapToNetworkDecodingException(): Unit = runBlocking {
        server.enqueue(MockResponse.Builder().body("not-an-int").build())
        val endpoint = object : APIDefinition<Int> {
            override fun request(baseUrl: HttpUrl): Request = Request.Builder()
                .url(
                    baseUrl.newBuilder()
                        .addPathSegment("number")
                        .addQueryParameter("token", "secret")
                        .build(),
                )
                .build()

            override fun decode(response: NetworkDataResponse): Int = response.bodyText().toInt()
        }

        val exception = assertThrows(NetworkDecodingException::class.java) {
            runBlocking {
                DefaultNetworkClient(server.url("/"), OkHttpNetworkSession()).request(endpoint)
            }
        }

        assertEquals(NumberFormatException::class.java, exception.cause?.javaClass)
        assertFalse(exception.message.orEmpty().contains("secret"))
    }

    private class TextEndpoint(
        private val pathSegment: String,
    ) : APIDefinition<String> {
        override fun request(baseUrl: HttpUrl): Request = Request.Builder()
            .url(baseUrl.newBuilder().addPathSegment(pathSegment).build())
            .build()

        override fun decode(response: NetworkDataResponse): String = response.bodyText()
    }
}
