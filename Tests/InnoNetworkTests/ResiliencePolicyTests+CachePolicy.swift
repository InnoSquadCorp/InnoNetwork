import Foundation
import InnoNetworkTestSupport
import Testing
import os

@testable import InnoNetwork

extension ResiliencePolicyTests {
    @Test("Response cache stores 204 responses without a body")
    func responseCacheStoresNoContentResponses() async throws {
        let cache = InMemoryResponseCache()
        let session = try ResilienceSequenceURLSession(queue: [
            resilienceQueuedResponse(statusCode: 204)
        ])
        let configuration = resilienceMakeLocalizedCacheConfiguration(
            responseCachePolicy: .cacheFirst(maxAge: .seconds(60)),
            responseCache: cache
        )
        let client = DefaultNetworkClient(configuration: configuration, session: session)

        _ = try await client.request(ResilienceCacheableEmptyRequest())

        let stored = try #require(
            await cache.get(
                ResponseCacheKey(
                    method: "GET",
                    url: "https://api.example.com/empty",
                    headers: ["Accept-Language": cacheFixtureAcceptLanguage]
                )
            )
        )
        #expect(stored.statusCode == 204)
    }

    @Test("Cache-Control no-store invalidates existing cached entries and skips writes")
    func cacheControlNoStoreInvalidatesExistingEntry() async throws {
        let cache = InMemoryResponseCache()
        let key = resilienceUserCacheKey()
        let staleBody = try JSONEncoder().encode(ResilienceUser(id: 1, name: "stale"))
        await cache.set(
            key,
            CachedResponse(
                data: staleBody,
                headers: ["ETag": "old"],
                storedAt: Date(timeIntervalSinceNow: -60)
            )
        )
        let fresh = ResilienceUser(id: 1, name: "fresh")
        let session = try ResilienceSequenceURLSession(queue: [
            resilienceQueuedResponse(statusCode: 200, body: fresh, headers: ["Cache-Control": "max-age=60, no-store"])
        ])
        let client = DefaultNetworkClient(
            configuration: resilienceMakeLocalizedCacheConfiguration(
                responseCachePolicy: .cacheFirst(maxAge: .seconds(1)),
                responseCache: cache
            ),
            session: session
        )

        let user = try await client.request(ResilienceGetRequest())

        #expect(user == fresh)
        #expect(await cache.get(key) == nil)
    }

    @Test("RFC 9111 no-store cached entries skip conditional revalidation")
    func rfc9111NoStoreCachedEntrySkipsConditionalRevalidation() async throws {
        let cache = InMemoryResponseCache()
        let key = resilienceUserCacheKey()
        let staleBody = try JSONEncoder().encode(ResilienceUser(id: 1, name: "stale-no-store"))
        await cache.set(
            key,
            CachedResponse(
                data: staleBody,
                headers: ["ETag": "old", "Cache-Control": "no-store"],
                storedAt: Date(timeIntervalSinceNow: -60)
            )
        )
        let fresh = ResilienceUser(id: 1, name: "fresh")
        let session = try ResilienceSequenceURLSession(queue: [
            resilienceQueuedResponse(statusCode: 200, body: fresh, headers: ["ETag": "new"])
        ])
        let client = DefaultNetworkClient(
            configuration: resilienceMakeLocalizedCacheConfiguration(
                responseCachePolicy: .rfc9111Compliant(wrapping: .cacheFirst(maxAge: .seconds(60))),
                responseCache: cache
            ),
            session: session
        )

        let user = try await client.request(ResilienceGetRequest())

        #expect(user == fresh)
        #expect(await session.capturedRequests.first?.value(forHTTPHeaderField: "If-None-Match") == nil)
        let refreshed = try #require(await cache.get(key))
        let decoded = try JSONDecoder().decode(ResilienceUser.self, from: refreshed.data)
        #expect(decoded == fresh)
    }

    @Test("Cache-Control private invalidates existing cached entries and skips writes")
    func cacheControlPrivateInvalidatesExistingEntry() async throws {
        let cache = InMemoryResponseCache()
        let key = resilienceUserCacheKey()
        let staleBody = try JSONEncoder().encode(ResilienceUser(id: 1, name: "stale"))
        await cache.set(
            key,
            CachedResponse(
                data: staleBody,
                headers: ["ETag": "old"],
                storedAt: Date(timeIntervalSinceNow: -60)
            )
        )
        let fresh = ResilienceUser(id: 1, name: "fresh-private")
        let session = try ResilienceSequenceURLSession(queue: [
            resilienceQueuedResponse(statusCode: 200, body: fresh, headers: ["Cache-Control": "max-age=60, private"])
        ])
        let client = DefaultNetworkClient(
            configuration: resilienceMakeLocalizedCacheConfiguration(
                responseCachePolicy: .cacheFirst(maxAge: .seconds(1)),
                responseCache: cache
            ),
            session: session
        )

        let user = try await client.request(ResilienceGetRequest())

        #expect(user == fresh)
        #expect(await cache.get(key) == nil)
    }

    @Test("Unsafe successful methods invalidate cached target URI before the next GET")
    func unsafeSuccessInvalidatesTargetURIBeforeNextGet() async throws {
        let cache = InMemoryResponseCache()
        let configuration = resilienceMakeLocalizedCacheConfiguration(
            responseCachePolicy: .cacheFirst(maxAge: .seconds(60)),
            responseCache: cache
        )
        let firstBody = ResilienceUser(id: 1, name: "cached")
        let firstSession = try ResilienceSequenceURLSession(queue: [
            resilienceQueuedResponse(statusCode: 200, body: firstBody)
        ])
        let firstClient = DefaultNetworkClient(configuration: configuration, session: firstSession)

        let first = try await firstClient.request(ResilienceGetRequest())
        #expect(first == firstBody)
        #expect(await cache.get(resilienceUserCacheKey()) != nil)

        let mutationSession = try ResilienceSequenceURLSession(queue: [
            resilienceQueuedResponse(statusCode: 200, body: ResilienceUser(id: 1, name: "mutated"))
        ])
        let mutationClient = DefaultNetworkClient(configuration: configuration, session: mutationSession)

        _ = try await mutationClient.request(ResilienceMutationRequest(method: .post))

        #expect(await cache.get(resilienceUserCacheKey()) == nil)

        let refreshedBody = ResilienceUser(id: 1, name: "refreshed")
        let refreshedSession = try ResilienceSequenceURLSession(queue: [
            resilienceQueuedResponse(statusCode: 200, body: refreshedBody)
        ])
        let refreshedClient = DefaultNetworkClient(configuration: configuration, session: refreshedSession)
        let refreshed = try await refreshedClient.request(ResilienceGetRequest())

        #expect(refreshed == refreshedBody)
        #expect(await refreshedSession.requestCount == 1)
    }

    @Test("PUT PATCH DELETE and 3xx successes invalidate cached target URI")
    func unsafeMethodsAndRedirectSuccessInvalidateTargetURI() async throws {
        let cases: [(HTTPMethod, Int)] = [
            (.put, 200),
            (.patch, 201),
            (.delete, 302),
        ]

        for (method, statusCode) in cases {
            let cache = InMemoryResponseCache()
            let key = resilienceUserCacheKey()
            await cache.set(
                key,
                CachedResponse(
                    data: try JSONEncoder().encode(ResilienceUser(id: 1, name: "stale")),
                    headers: ["ETag": "old"]
                )
            )
            let configuration = resilienceMakeLocalizedCacheConfiguration(
                responseCachePolicy: .cacheFirst(maxAge: .seconds(60)),
                responseCache: cache
            )
            let session = try ResilienceSequenceURLSession(queue: [
                resilienceQueuedResponse(
                    statusCode: statusCode,
                    body: ResilienceUser(id: statusCode, name: method.rawValue.lowercased())
                )
            ])
            let client = DefaultNetworkClient(configuration: configuration, session: session)

            _ = try await client.request(
                ResilienceMutationRequest(
                    method: method,
                    acceptedStatusCodes: Set(200..<400)
                )
            )

            #expect(await cache.get(key) == nil)
        }
    }

    @Test("Unknown and differently cased successful methods invalidate the target URI")
    func customSuccessfulMethodsInvalidateTargetURI() async throws {
        for method in ["PURGE", "options", "trace"] {
            let cache = InMemoryResponseCache()
            let key = resilienceUserCacheKey()
            await cache.set(
                key,
                CachedResponse(
                    data: try JSONEncoder().encode(ResilienceUser(id: 1, name: "stale")),
                    headers: ["ETag": "old"]
                )
            )
            let configuration = resilienceMakeLocalizedCacheConfiguration(
                responseCachePolicy: .cacheFirst(maxAge: .seconds(60)),
                responseCache: cache
            )
            let session = try ResilienceSequenceURLSession(queue: [
                resilienceQueuedResponse(statusCode: 200, body: ResilienceUser(id: 1, name: method))
            ])
            let client = DefaultNetworkClient(configuration: configuration, session: session)

            _ = try await client.request(
                InterceptedResilienceGetRequest(
                    interceptors: [ResilienceHTTPMethodOverrideInterceptor(method: method)]
                )
            )

            #expect(await cache.get(key) == nil)
        }
    }

    @Test("Unsafe error responses and transport failures keep cached target URI")
    func unsafeErrorsAndTransportFailuresKeepTargetURI() async throws {
        for statusCode in [400, 500] {
            let cache = InMemoryResponseCache()
            let key = resilienceUserCacheKey()
            await cache.set(
                key,
                CachedResponse(
                    data: try JSONEncoder().encode(ResilienceUser(id: 1, name: "stale")),
                    headers: ["ETag": "old"]
                )
            )
            let configuration = resilienceMakeLocalizedCacheConfiguration(
                responseCachePolicy: .cacheFirst(maxAge: .seconds(60)),
                responseCache: cache
            )
            let session = try ResilienceSequenceURLSession(queue: [
                resilienceQueuedResponse(statusCode: statusCode, body: ResilienceUser(id: statusCode, name: "error"))
            ])
            let client = DefaultNetworkClient(configuration: configuration, session: session)

            _ = try await client.request(
                ResilienceMutationRequest(
                    method: .delete,
                    acceptedStatusCodes: [statusCode]
                )
            )

            #expect(await cache.get(key) != nil)
        }

        let cache = InMemoryResponseCache()
        let key = resilienceUserCacheKey()
        await cache.set(
            key,
            CachedResponse(
                data: try JSONEncoder().encode(ResilienceUser(id: 1, name: "stale")),
                headers: ["ETag": "old"]
            )
        )
        let configuration = resilienceMakeLocalizedCacheConfiguration(
            responseCachePolicy: .cacheFirst(maxAge: .seconds(60)),
            responseCache: cache
        )
        let client = DefaultNetworkClient(
            configuration: configuration, session: ResilienceSequenceURLSession(queue: []))

        do {
            _ = try await client.request(ResilienceMutationRequest(method: .delete))
            Issue.record("Expected transport failure")
        } catch {
            #expect(await cache.get(key) != nil)
        }
    }

    @Test("Network-only and disabled cache policies do not invalidate unsafe successes")
    func metadataUntouchedPoliciesSkipUnsafeInvalidation() async throws {
        for policy in [ResponseCachePolicy.networkOnly, .disabled] {
            let cache = InMemoryResponseCache()
            let key = resilienceUserCacheKey()
            await cache.set(
                key,
                CachedResponse(
                    data: try JSONEncoder().encode(ResilienceUser(id: 1, name: "stale")),
                    headers: ["ETag": "old"]
                )
            )
            let configuration = resilienceMakeLocalizedCacheConfiguration(
                responseCachePolicy: policy,
                responseCache: cache
            )
            let session = try ResilienceSequenceURLSession(queue: [
                resilienceQueuedResponse(statusCode: 200, body: ResilienceUser(id: 1, name: "mutated"))
            ])
            let client = DefaultNetworkClient(configuration: configuration, session: session)

            _ = try await client.request(ResilienceMutationRequest(method: .post))

            #expect(await cache.get(key) != nil)
        }
    }

    @Test("Cache-Control no-cache entries are stored but always revalidated")
    func cacheControlNoCacheForcesRevalidation() async throws {
        let cache = InMemoryResponseCache()
        let cached = ResilienceUser(id: 1, name: "requires-revalidation")
        let initialSession = try ResilienceSequenceURLSession(queue: [
            resilienceQueuedResponse(
                statusCode: 200,
                body: cached,
                headers: ["ETag": "v1", "Cache-Control": "no-cache, max-age=60"]
            )
        ])
        let configuration = resilienceMakeLocalizedCacheConfiguration(
            responseCachePolicy: .cacheFirst(maxAge: .seconds(60)),
            responseCache: cache
        )
        let initialClient = DefaultNetworkClient(configuration: configuration, session: initialSession)

        _ = try await initialClient.request(ResilienceGetRequest())

        let stored = try #require(await cache.get(resilienceUserCacheKey()))
        #expect(stored.requiresRevalidation)

        let revalidationSession = try ResilienceSequenceURLSession(queue: [
            resilienceQueuedResponse(statusCode: 304, headers: ["ETag": "v2"])
        ])
        let revalidationClient = DefaultNetworkClient(configuration: configuration, session: revalidationSession)
        let user = try await revalidationClient.request(ResilienceGetRequest())

        #expect(user == cached)
        #expect(await revalidationSession.requestCount == 1)
        #expect(await revalidationSession.capturedRequests.first?.value(forHTTPHeaderField: "If-None-Match") == "v1")
    }

    @Test("Response cache keeps different Accept-Language headers separate")
    func responseCacheSeparatesAcceptLanguageHeaders() async throws {
        let cache = InMemoryResponseCache()
        let session = try ResilienceSequenceURLSession(queue: [
            resilienceQueuedResponse(statusCode: 200, body: ResilienceUser(id: 1, name: "ko")),
            resilienceQueuedResponse(statusCode: 200, body: ResilienceUser(id: 2, name: "en")),
        ])
        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(
                baseURL: "https://api.example.com",
                responseCachePolicy: .cacheFirst(maxAge: .seconds(60)),
                responseCache: cache
            ),
            session: session
        )

        let korean = try await client.request(
            InterceptedResilienceGetRequest(
                interceptors: [ResilienceHeaderSettingInterceptor(field: "Accept-Language", value: "ko-KR")]
            )
        )
        let english = try await client.request(
            InterceptedResilienceGetRequest(
                interceptors: [ResilienceHeaderSettingInterceptor(field: "Accept-Language", value: "en-US")]
            )
        )

        #expect(korean == ResilienceUser(id: 1, name: "ko"))
        #expect(english == ResilienceUser(id: 2, name: "en"))
        #expect(await session.requestCount == 2)
    }

    @Test("Network-only cache policy does not substitute cached 304 bodies")
    func networkOnlyDoesNotSubstituteNotModified() async throws {
        let cache = InMemoryResponseCache()
        let key = ResponseCacheKey(method: "GET", url: "https://api.example.com/users/1")
        let body = try JSONEncoder().encode(ResilienceUser(id: 1, name: "cached"))
        await cache.set(key, CachedResponse(data: body, headers: ["ETag": "v1"]))
        let session = try ResilienceSequenceURLSession(queue: [resilienceQueuedResponse(statusCode: 304)])
        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(
                baseURL: "https://api.example.com",
                responseCachePolicy: .networkOnly,
                responseCache: cache
            ),
            session: session
        )

        await #expect(throws: NetworkError.self) {
            try await client.request(ResilienceGetRequest())
        }
        #expect(await session.capturedRequests.first?.value(forHTTPHeaderField: "If-None-Match") == nil)
    }

    @Test("Network-only cache policy does not write the response into the cache")
    func responseCacheNetworkOnlySkipsCacheWrite() async throws {
        let cache = InMemoryResponseCache()
        let body = ResilienceUser(id: 1, name: "fresh")
        let session = try ResilienceSequenceURLSession(queue: [
            resilienceQueuedResponse(statusCode: 200, body: body, headers: ["ETag": "v1"])
        ])
        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(
                baseURL: "https://api.example.com",
                responseCachePolicy: .networkOnly,
                responseCache: cache
            ),
            session: session
        )

        let user = try await client.request(ResilienceGetRequest())

        #expect(user == body)
        let stored = await cache.get(
            ResponseCacheKey(method: "GET", url: "https://api.example.com/users/1")
        )
        #expect(stored == nil)
    }

    @Test("Network-only cache policy does not touch configured cache")
    func responseCacheNetworkOnlySkipsCacheReadsWritesAndInvalidation() async throws {
        let cachedBody = try JSONEncoder().encode(ResilienceUser(id: 1, name: "cached"))
        let cache = ResilienceCountingResponseCache(
            cached: CachedResponse(data: cachedBody, headers: ["ETag": "v1"])
        )
        let body = ResilienceUser(id: 2, name: "fresh")
        let session = try ResilienceSequenceURLSession(queue: [
            resilienceQueuedResponse(
                statusCode: 200,
                body: body,
                headers: ["Cache-Control": "no-store"]
            )
        ])
        let client = DefaultNetworkClient(
            configuration: makeTestNetworkConfiguration(
                baseURL: "https://api.example.com",
                responseCachePolicy: .networkOnly,
                responseCache: cache
            ),
            session: session
        )

        let user = try await client.request(ResilienceGetRequest())

        #expect(user == body)
        #expect(await cache.getCount == 0)
        #expect(await cache.setCount == 0)
        #expect(await cache.invalidateCount == 0)
        #expect(await session.requestCount == 1)
    }

}
