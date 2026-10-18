# InnoNetwork Android

InnoNetwork Android is a thin coroutine bridge over OkHttp. It replaces
Retrofit's execution and optional endpoint-generation role while leaving
transport ownership with OkHttp.

## Modules

- `innonetwork` — `NetworkSession`, `OkHttpNetworkSession`, bounded buffering,
  caller-owned streaming, and typed transport/status failures.
- `innonetwork-client` — `APIDefinition`, `NetworkClient`, endpoint annotations,
  and `DefaultNetworkClient`.
- `innonetwork-ksp` — optional compile-time native request generation.
- `innonetwork-kotlinx-serialization` — optional explicit JSON helpers.

The core accepts `okhttp3.Request` directly. Configure interceptors, TLS,
cookies, cache, authenticators, connection pooling, proxies, and event listeners
on the injected `OkHttpClient`; InnoNetwork does not mirror those APIs.

## Local release-candidate installation

Before public registry publication, either use a composite build or publish to
the checkout's local preview repository. Application dependencies are:

```kotlin
dependencies {
    implementation("com.innosquad.innonetwork:innonetwork:1.0.0")
    implementation("com.innosquad.innonetwork:innonetwork-client:1.0.0")
    implementation("com.innosquad.innonetwork:innonetwork-kotlinx-serialization:1.0.0")
    ksp("com.innosquad.innonetwork:innonetwork-ksp:1.0.0")
}
```

For a composite build, add:

```kotlin
includeBuild("/absolute/path/to/InnoNetwork/Platforms/Android")
```

Apply the `com.google.devtools.ksp` plugin in modules using `ksp(...)`. The
verified toolchain is Kotlin 2.4.10, KSP 2.3.11, AGP 9.3.0, and JDK 17. For
local Maven installation, run the repository's `Scripts/check_cross_platform.sh`
and add a Maven repository pointing to
`/absolute/path/to/InnoNetwork/Platforms/Android/build/preview-repository` in the
application's dependency resolution settings. It contains actual 1.0.0 artifacts.

## Native low-level request

```kotlin
val okHttpClient = OkHttpClient.Builder()
    .addInterceptor(authenticationInterceptor)
    .build()
val session: NetworkSession = OkHttpNetworkSession(okHttpClient)

val response = session.data(
    Request.Builder()
        .url("https://api.example.com/users/42")
        .header("Accept", "application/json")
        .build(),
)
response.requireSuccessful()
```

As with OkHttp and `URLSession.data(for:)`, 4xx and 5xx responses are values.
`requireSuccessful()` is an explicit application-policy step.

## KSP-first typed endpoint

```kotlin
@InnoEndpoint(method = InnoHttpMethod.GET, path = "/users/{id}")
data class GetUser(
    @InnoPath val id: String,
    @InnoQuery("locale") val locale: String?,
    @InnoHeader("X-Request-ID") val requestID: String,
)

val client: NetworkClient = DefaultNetworkClient(baseUrl, session)
val user = client.request(
    GetUser("42", "ko-KR", requestID).apiDefinition { response ->
        response.decodeJson(User.serializer())
    },
)
```

`@InnoBody` accepts a native `RequestBody`. For body-required OkHttp methods
(`POST`, `PUT`, `PATCH`, `PROPPATCH`, `QUERY`, and `REPORT`), omit `@InnoBody`
only when an intentional empty body is desired. Complex or dynamic requests can
implement `APIDefinition` directly and use the same client.

Concrete native body types such as `MultipartBody` are accepted. The generator
supports top-level public/internal endpoints, public/internal annotated
properties, default and keyword packages, and names that also occur in the
native transport API. Required trailing slashes are preserved.

Generated relative paths reject literal `.` and `..` segments at compile time
and reject placeholder values that resolve to either segment at request-build
time. OkHttp therefore cannot normalize a generated endpoint outside the
configured base path. Dynamic URLs remain an explicit manual `APIDefinition`
responsibility.

## Cancellation and large responses

Coroutine cancellation cancels the active OkHttp `Call`. `data()` buffers at
most 10 MiB by default. Choose a smaller ceiling when appropriate:

```kotlin
val session = OkHttpNetworkSession(
    okHttpClient,
    NetworkSessionConfiguration.bounded(2L * 1024L * 1024L),
)
```

Use `open()` for large downloads and indefinite streams. The caller owns the
native response and must close it:

```kotlin
session.open(request).use { response ->
    while (!response.source.exhausted()) {
        consume(response.source.readUtf8Line())
    }
}
```

Cancelling while waiting for headers cancels the call. After `open()` returns,
the caller may call `cancel()` on the wrapper to abort the stream.

Already cancelled coroutines do not create calls. Buffered responses close
before `data()` returns, including when a custom body fails. Custom factory/body
exceptions reach the suspended caller; I/O failures remain typed transport
exceptions. Reuse a configured `OkHttpClient`/session for normal applications.

## Build and release-candidate verification

```bash
./gradlew testDebugUnitTest :innonetwork-ksp:test lint \
  :innonetwork-ksp:checkKotlinAbi publishAllPublicationsToPreviewRepository
../../Scripts/check_android_wrapper_integrity.sh
../../Scripts/check_android_release_artifacts.sh
../../Scripts/check_android_public_api.sh
```

The build targets Android 5.0 (API 21) and newer, compiles against API 37, and
emits Java 11-compatible bytecode. CI covers JDK 17 and 21. Dependency
verification is strict; the wrapper URL, distribution checksum, validation flag,
and wrapper JAR checksum are repository gates. Local publication produces
AAR/JAR binaries, sources, Dokka documentation, POM/Gradle metadata, and
checksums without claiming a remote registry release.

The independent consumer also builds a minified API-21-targeted APK with R8.
After building it, run `node Scripts/check_android_device_smoke.mjs <adb-serial>`
from the repository root to test a connected Android target. The command
installs an isolated test app, uses a loopback HTTP fixture and temporary
`adb reverse` mapping, then removes the test app and mapping. It does not reset
other apps or clear logs. See [release readiness](../RELEASE_READINESS.md) for
actual runtime evidence and remaining qualifications.
