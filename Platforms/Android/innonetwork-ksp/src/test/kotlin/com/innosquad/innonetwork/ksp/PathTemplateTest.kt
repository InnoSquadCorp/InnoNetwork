package com.innosquad.innonetwork.ksp

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

public class PathTemplateTest {
    @Test
    public fun parsesLiteralAndPlaceholderSegments(): Unit {
        val template = PathTemplate.parse("/users/{id}/posts").getOrThrow()

        assertEquals(
            listOf(
                PathSegment.Literal("users"),
                PathSegment.Placeholder("id"),
                PathSegment.Literal("posts"),
            ),
            template.segments,
        )
        assertEquals(setOf("id"), template.placeholders)
    }

    @Test
    public fun rejectsPartialPlaceholderSegments(): Unit {
        val result = PathTemplate.parse("/users/prefix-{id}")

        assertTrue(result.isFailure)
        assertTrue(result.exceptionOrNull()?.message.orEmpty().contains("complete segment"))
    }

    @Test
    public fun rejectsQueriesInThePathContract(): Unit {
        val result = PathTemplate.parse("/users?admin=true")

        assertTrue(result.isFailure)
        assertTrue(result.exceptionOrNull()?.message.orEmpty().contains("query string"))
    }

    @Test
    public fun rejectsDotSegmentsThatCouldEscapeTheBasePath(): Unit {
        listOf("/users/./profile", "/users/../admin").forEach { path ->
            val result = PathTemplate.parse(path)

            assertTrue(result.isFailure)
            assertTrue(result.exceptionOrNull()?.message.orEmpty().contains("dot segments"))
        }
    }

    @Test
    public fun preservesATrailingSlashWithoutAllowingEmptyInteriorSegments(): Unit {
        val template = PathTemplate.parse("/users/").getOrThrow()

        assertEquals(listOf(PathSegment.Literal("users"), PathSegment.Literal("")), template.segments)
        assertTrue(PathTemplate.parse("/users//profile").isFailure)
    }
}
