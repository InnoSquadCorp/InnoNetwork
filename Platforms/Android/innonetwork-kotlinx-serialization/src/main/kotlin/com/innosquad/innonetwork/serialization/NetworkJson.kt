package com.innosquad.innonetwork.serialization

import com.innosquad.innonetwork.NetworkDataResponse
import com.innosquad.innonetwork.NetworkDecodingException
import kotlinx.serialization.DeserializationStrategy
import kotlinx.serialization.SerializationException
import kotlinx.serialization.SerializationStrategy
import kotlinx.serialization.json.Json
import okhttp3.MediaType
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.RequestBody
import okhttp3.RequestBody.Companion.toRequestBody

/** Shared conservative JSON defaults for InnoNetwork Android. */
public object NetworkJson {
    /**
     * A JSON codec that tolerates additive server fields while preserving explicit model defaults.
     */
    public val default: Json = Json {
        ignoreUnknownKeys = true
        encodeDefaults = true
    }
}

/** Decodes this response with [deserializer] and [NetworkJson.default]. */
public fun <T> NetworkDataResponse.decodeJson(
    deserializer: DeserializationStrategy<T>,
): T = decodeJson(deserializer, NetworkJson.default)

/** Decodes this response with an explicit [json] configuration. */
public fun <T> NetworkDataResponse.decodeJson(
    deserializer: DeserializationStrategy<T>,
    json: Json,
): T {
    try {
        return json.decodeFromString(deserializer, bodyText())
    } catch (exception: SerializationException) {
        throw NetworkDecodingException(this, exception)
    }
}

/** Encodes [value] as an `application/json; charset=utf-8` OkHttp request body. */
public fun <T> encodeJsonRequestBody(
    serializer: SerializationStrategy<T>,
    value: T,
): RequestBody = encodeJsonRequestBody(serializer, value, NetworkJson.default, JSON_MEDIA_TYPE)

/** Encodes [value] with explicit codec and media-type policy. */
public fun <T> encodeJsonRequestBody(
    serializer: SerializationStrategy<T>,
    value: T,
    json: Json,
    mediaType: MediaType,
): RequestBody {
    try {
        return json.encodeToString(serializer, value).toRequestBody(mediaType)
    } catch (exception: SerializationException) {
        throw NetworkEncodingException(exception)
    }
}

private val JSON_MEDIA_TYPE: MediaType = "application/json; charset=utf-8".toMediaType()
