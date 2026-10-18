package com.innosquad.innonetwork

/** Immutable buffering policy for a [NetworkSession]. */
public class NetworkSessionConfiguration private constructor(
    /** Maximum buffered response size, or `null` when no library-level limit is applied. */
    public val maxResponseBodyBytes: Long?,
) {
    init {
        require(maxResponseBodyBytes == null || maxResponseBodyBytes >= 0L) {
            "maxResponseBodyBytes must be non-negative"
        }
    }

    public companion object {
        /** Default response ceiling used by [safeDefaults]. */
        public const val DEFAULT_MAX_RESPONSE_BODY_BYTES: Long = 10L * 1024L * 1024L

        /** Creates a session policy with a conservative 10 MiB response ceiling. */
        @JvmStatic
        public fun safeDefaults(): NetworkSessionConfiguration =
            NetworkSessionConfiguration(DEFAULT_MAX_RESPONSE_BODY_BYTES)

        /** Creates a session policy with the supplied response ceiling. */
        @JvmStatic
        public fun bounded(maxResponseBodyBytes: Long): NetworkSessionConfiguration =
            NetworkSessionConfiguration(maxResponseBodyBytes)

        /**
         * Creates a policy without a library-level response ceiling.
         *
         * Prefer OkHttp streaming APIs for large or untrusted payloads. This option mirrors
         * unbounded `URLSession.data(for:)` behavior and can exhaust application memory.
         */
        @JvmStatic
        public fun unbounded(): NetworkSessionConfiguration = NetworkSessionConfiguration(null)
    }
}
