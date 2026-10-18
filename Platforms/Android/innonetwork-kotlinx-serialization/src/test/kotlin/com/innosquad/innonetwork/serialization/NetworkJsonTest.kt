package com.innosquad.innonetwork.serialization

import com.innosquad.innonetwork.NetworkDataResponse
import com.innosquad.innonetwork.NetworkDecodingException
import kotlinx.serialization.builtins.serializer
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import okhttp3.Headers
import okhttp3.Protocol
import okhttp3.Request
import okhttp3.RequestBody
import okio.ByteString.Companion.encodeUtf8
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

public class NetworkJsonTest {
    @Test
    public fun decodeJsonUsesRuntimeSerializer(): Unit {
        val response = response("{\"name\":\"Inno\",\"futureField\":true}")

        val decoded = response.decodeJson(JsonObject.serializer())

        assertEquals("Inno", decoded["name"]?.jsonPrimitive?.content)
    }

    @Test
    public fun decodeJsonMapsMalformedPayloadWithoutExposingBodyInMessage(): Unit {
        val response = response("not-json")

        val exception = assertThrows(NetworkDecodingException::class.java) {
            response.decodeJson(JsonObject.serializer())
        }

        assertEquals(response, exception.response)
        assertEquals(false, exception.message?.contains("not-json"))
    }

    @Test
    public fun encodeJsonRequestBodyProducesNativeOkHttpBody(): Unit {
        val requestBody: RequestBody = encodeJsonRequestBody(String.serializer(), "hello")
        val buffer = okio.Buffer()

        requestBody.writeTo(buffer)

        assertEquals("\"hello\"", buffer.readUtf8())
        assertEquals("application/json; charset=utf-8", requestBody.contentType().toString())
    }

    private fun response(body: String): NetworkDataResponse {
        val request = Request.Builder().url("https://example.com/value").build()
        return NetworkDataResponse(
            request = request,
            url = request.url,
            statusCode = 200,
            statusMessage = "OK",
            headers = Headers.Builder().build(),
            protocol = Protocol.HTTP_2,
            contentType = null,
            sentRequestAtMillis = 1L,
            receivedResponseAtMillis = 2L,
            body = body.encodeUtf8(),
        )
    }
}
