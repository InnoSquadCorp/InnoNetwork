package com.innosquad.innonetwork.serialization

import kotlinx.serialization.SerializationException

/** A request value could not be encoded by the selected serializer. */
public class NetworkEncodingException(
    cause: SerializationException,
) : IllegalArgumentException("Failed to encode JSON request body", cause)
