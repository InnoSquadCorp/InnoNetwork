package com.innosquad.innonetwork.invalidsmoke

import com.innosquad.innonetwork.client.codegen.InnoEndpoint
import com.innosquad.innonetwork.client.codegen.InnoBody
import com.innosquad.innonetwork.client.codegen.InnoHeader
import com.innosquad.innonetwork.client.codegen.InnoHttpMethod
import com.innosquad.innonetwork.client.codegen.InnoPath
import okhttp3.RequestBody

@InnoEndpoint(method = InnoHttpMethod.GET, path = "/users/{id}")
public data class InvalidEndpoint public constructor(
    @InnoPath public val userID: String,
)

@InnoEndpoint(method = "get", path = "/users")
public class LowercaseMethodEndpoint

@InnoEndpoint(method = InnoHttpMethod.POST, path = "/users")
public data class NullableBodyEndpoint public constructor(
    @InnoBody public val body: RequestBody?,
)

@InnoEndpoint(method = InnoHttpMethod.GET, path = "/users")
public data class InvalidHeaderEndpoint public constructor(
    @InnoHeader("Bad Header") public val value: String,
)

@InnoEndpoint(method = InnoHttpMethod.GET, path = "/users")
public data class DuplicateHeaderEndpoint public constructor(
    @InnoHeader("X-Request-ID") public val first: String,
    @InnoHeader("x-request-id") public val second: String,
)

@InnoEndpoint(method = InnoHttpMethod.GET, path = "/users/../admin")
public class DotSegmentEndpoint

@InnoEndpoint(method = InnoHttpMethod.GET, path = "/users/{id}")
public data class InaccessiblePathEndpoint public constructor(
    @InnoPath private val id: String,
)
