package com.innosquad.innonetwork.client

import com.innosquad.innonetwork.HttpStatusException
import com.innosquad.innonetwork.NetworkDecodingException
import com.innosquad.innonetwork.NetworkSession
import java.util.concurrent.CancellationException
import okhttp3.HttpUrl

/** Default typed client layered on the native low-level [NetworkSession]. */
public class DefaultNetworkClient public constructor(
    private val baseUrl: HttpUrl,
    private val session: NetworkSession,
) : NetworkClient {
    override suspend fun <Response> request(definition: APIDefinition<Response>): Response {
        val response = session.data(definition.request(baseUrl))
        if (!definition.acceptsStatusCode(response.statusCode)) {
            throw HttpStatusException(response)
        }

        return try {
            definition.decode(response)
        } catch (exception: CancellationException) {
            throw exception
        } catch (exception: NetworkDecodingException) {
            throw exception
        } catch (exception: Exception) {
            throw NetworkDecodingException(response, exception)
        }
    }
}
