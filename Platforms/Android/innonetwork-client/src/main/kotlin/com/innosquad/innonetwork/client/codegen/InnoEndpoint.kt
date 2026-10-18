package com.innosquad.innonetwork.client.codegen

/** Marks an endpoint value for optional InnoNetwork KSP request generation. */
@MustBeDocumented
@Retention(AnnotationRetention.SOURCE)
@Target(AnnotationTarget.CLASS)
public annotation class InnoEndpoint(
    /** Uppercase native HTTP method token. Prefer [InnoHttpMethod] constants. */
    public val method: String,
    /** Relative path without `.` or `..` segments; placeholders use `{propertyName}` syntax. */
    public val path: String,
)

/** Marks a non-null scalar property that fills a complete path segment placeholder. */
@MustBeDocumented
@Retention(AnnotationRetention.SOURCE)
@Target(AnnotationTarget.PROPERTY)
public annotation class InnoPath

/** Adds a scalar property as a query item. Null values are omitted. */
@MustBeDocumented
@Retention(AnnotationRetention.SOURCE)
@Target(AnnotationTarget.PROPERTY)
public annotation class InnoQuery(
    /** Wire name. An empty value uses the Kotlin property name. */
    public val name: String = "",
)

/** Adds a scalar property as a native OkHttp header. Null values are omitted. */
@MustBeDocumented
@Retention(AnnotationRetention.SOURCE)
@Target(AnnotationTarget.PROPERTY)
public annotation class InnoHeader(
    /** Wire name. An empty value uses the Kotlin property name. */
    public val name: String = "",
)

/** Supplies the endpoint's native OkHttp request body. At most one property may be marked. */
@MustBeDocumented
@Retention(AnnotationRetention.SOURCE)
@Target(AnnotationTarget.PROPERTY)
public annotation class InnoBody

/** Stable string constants for [InnoEndpoint.method] without a closed enum contract. */
public object InnoHttpMethod {
    public const val GET: String = "GET"
    public const val HEAD: String = "HEAD"
    public const val POST: String = "POST"
    public const val PUT: String = "PUT"
    public const val PATCH: String = "PATCH"
    public const val DELETE: String = "DELETE"
    public const val OPTIONS: String = "OPTIONS"
    public const val TRACE: String = "TRACE"
}
