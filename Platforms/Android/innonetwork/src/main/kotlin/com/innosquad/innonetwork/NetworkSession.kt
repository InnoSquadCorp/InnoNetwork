package com.innosquad.innonetwork

import okhttp3.Request

/**
 * Executes native OkHttp requests without imposing an endpoint DSL.
 *
 * HTTP status codes, including 4xx and 5xx responses, are returned as data.
 * I/O failures use [NetworkTransportException]; exceeding the configured body ceiling uses
 * [ResponseBodyTooLargeException]. Cancellation stays a coroutine cancellation. Exceptions
 * from caller-supplied factories or bodies propagate to the suspended caller unchanged.
 */
public fun interface NetworkSession {
    /** Executes [request] and buffers its response according to the session policy. */
    public suspend fun data(request: Request): NetworkDataResponse
}

/** Executes native OkHttp requests without buffering their response bodies. */
public fun interface StreamingNetworkSession {
    /**
     * Opens [request] and returns after the response headers arrive.
     *
     * The caller owns the returned response and must close it, normally with `use`. Cancelling
     * while awaiting headers cancels the OkHttp call. After this method returns, [NetworkStreamingResponse.cancel]
     * is the explicit cancellation boundary for the caller-owned stream.
     */
    public suspend fun open(request: Request): NetworkStreamingResponse
}
