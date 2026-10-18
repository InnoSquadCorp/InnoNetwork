package com.innosquad.innonetwork.consumersmoke

import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.MultipartBody
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertThrows
import org.junit.Test

public class GeneratedEndpointTest {
    @Test
    public fun generatedAdapterBuildsNativeOkHttpRequest(): Unit {
        val definition = MessageEndpoint(
            pathSegment = "hello world",
            locale = "ko-KR",
            requestID = "request-1",
        ).apiDefinition { response -> response.statusCode }

        val request = definition.request("https://example.com/api/".toHttpUrl())

        assertEquals("https://example.com/api/messages/hello%20world?locale=ko-KR", request.url.toString())
        assertEquals("request-1", request.header("X-Request-ID"))
        assertEquals("GET", request.method)
    }

    @Test
    public fun generatedAdapterForwardsNativeRequestBody(): Unit {
        val body = "hello".toRequestBody("text/plain".toMediaType())
        val definition = CreateMessageEndpoint(body).apiDefinition { response -> response.statusCode }

        val request = definition.request("https://example.com/api/".toHttpUrl())

        assertEquals("https://example.com/api/messages", request.url.toString())
        assertEquals("POST", request.method)
        assertEquals(body, request.body)
    }

    @Test
    public fun generatedAdapterSuppliesAnEmptyBodyForOkHttpRequiredCustomMethods(): Unit {
        val definition = ReportEndpoint().apiDefinition { response -> response.statusCode }

        val request = definition.request("https://example.com/api/".toHttpUrl())

        assertEquals("REPORT", request.method)
        assertNotNull(request.body)
        assertEquals(0L, request.body?.contentLength())
    }

    @Test
    public fun generatedAdapterRejectsRuntimeDotSegmentsBeforeOkHttpNormalization(): Unit {
        listOf(".", "..").forEach { pathSegment ->
            val definition = MessageEndpoint(
                pathSegment = pathSegment,
                locale = null,
                requestID = "request-1",
            ).apiDefinition { response -> response.statusCode }

            val exception = assertThrows(IllegalArgumentException::class.java) {
                definition.request("https://example.com/api/".toHttpUrl())
            }

            assertEquals(
                "@InnoPath pathSegment must not resolve to a dot segment",
                exception.message,
            )
        }
    }

    @Test
    public fun generatedAdapterAcceptsConcreteNativeRequestBodySubtypes(): Unit {
        val body = MultipartBody.Builder().setType(MultipartBody.FORM)
            .addFormDataPart("message", "hello").build()

        val request = MultipartEndpoint(body).apiDefinition { it.statusCode }
            .request("https://example.com/api/".toHttpUrl())

        assertEquals(body, request.body)
        assertEquals("/api/multipart", request.url.encodedPath)
    }
}
