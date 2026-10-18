package com.innosquad.innonetwork.ksp

internal sealed interface PathSegment {
    data class Literal(val value: String) : PathSegment

    data class Placeholder(val propertyName: String) : PathSegment
}

internal data class PathTemplate(
    val segments: List<PathSegment>,
    val placeholders: Set<String>,
) {
    companion object {
        fun parse(rawPath: String): Result<PathTemplate> = runCatching {
            require('?' !in rawPath && '#' !in rawPath) {
                "path must not contain a query string or fragment"
            }

            val normalized = rawPath.trimStart('/')
            if (normalized.isEmpty()) {
                return@runCatching PathTemplate(emptyList(), emptySet())
            }

            val placeholders = linkedSetOf<String>()
            val rawSegments = normalized.split('/')
            val segments = rawSegments.mapIndexed { index, segment ->
                require(segment.isNotEmpty() || index == rawSegments.lastIndex) {
                    "path contains an empty segment at index $index"
                }
                require(segment != "." && segment != "..") {
                    "path must not contain dot segments"
                }
                val placeholder = PLACEHOLDER.matchEntire(segment)?.groupValues?.get(1)
                when {
                    placeholder != null -> {
                        require(placeholders.add(placeholder)) {
                            "path placeholder {$placeholder} appears more than once"
                        }
                        PathSegment.Placeholder(placeholder)
                    }

                    '{' in segment || '}' in segment -> error(
                        "path placeholders must occupy a complete segment",
                    )

                    else -> PathSegment.Literal(segment)
                }
            }
            PathTemplate(segments, placeholders)
        }

        private val PLACEHOLDER: Regex = Regex("\\{([A-Za-z_][A-Za-z0-9_]*)}")
    }
}
