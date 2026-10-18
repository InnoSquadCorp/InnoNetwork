package com.innosquad.innonetwork.client

import com.innosquad.innonetwork.HttpStatusException
import com.innosquad.innonetwork.NetworkDecodingException
import com.innosquad.innonetwork.NetworkSession
import java.util.concurrent.CancellationException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.HttpUrl

/**
 * Default typed client layered on the native low-level [NetworkSession].
 *
 * Decoding runs on [decodingDispatcher], not the caller's main thread. Request construction
 * and status policies must remain lightweight. No scope or detached work is created.
 */
public class DefaultNetworkClient public constructor(
    private val baseUrl: HttpUrl,
    private val session: NetworkSession,
    private val decodingDispatcher: CoroutineDispatcher,
) : NetworkClient {
    /** Creates a client that decodes buffered responses on [Dispatchers.Default]. */
    public constructor(baseUrl: HttpUrl, session: NetworkSession) :
        this(baseUrl, session, Dispatchers.Default)

    override suspend fun <Response> request(definition: APIDefinition<Response>): Response {
        val response = session.data(definition.request(baseUrl))
        if (!definition.acceptsStatusCode(response.statusCode)) {
            throw HttpStatusException(response)
        }

        return try {
            withContext(decodingDispatcher) { definition.decode(response) }
        } catch (exception: CancellationException) {
            throw exception
        } catch (exception: NetworkDecodingException) {
            throw exception
        } catch (exception: Exception) {
            throw NetworkDecodingException(response, exception)
        }
    }
}
