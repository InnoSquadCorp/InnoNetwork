package com.innosquad.innonetwork.client

/** Executes typed [APIDefinition] values. */
public interface NetworkClient {
    /** Builds, executes, validates, and decodes [definition]. */
    public suspend fun <Response> request(definition: APIDefinition<Response>): Response
}
