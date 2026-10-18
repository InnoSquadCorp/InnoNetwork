# InnoNetwork Web

`@innosquad/innonetwork` is a zero-runtime-dependency wrapper around native
Fetch. It works in browsers, workers, React/Next.js client code, and Node
runtimes that provide Fetch.

It does not own UI state, caching, server authorization, CORS, cookies, CSRF, or
retry policy. Those remain application and platform concerns.

## Local release-candidate installation

Until npm publication, build and pack the checkout, then install its tarball:

```bash
cd /absolute/path/to/InnoNetwork/Platforms/Web
npm ci --ignore-scripts --no-audit
npm pack
# From the consuming application:
npm install /absolute/path/to/InnoNetwork/Platforms/Web/innosquad-innonetwork-1.0.0.tgz
```

The package includes emitted code, declarations, source-map targets, and its
license. Node-only TypeScript consumers can use `lib: ["ES2022"]` with
`@types/node` without DOM declarations.

## Buffered request

```ts
const session = new FetchNetworkSession({
  baseUrl: "https://api.example.com/v1/",
  defaultHeaders: { Accept: "application/json" },
});

const response = await session.data("users/42", {
  credentials: "include",
});
response.requireSuccessful();
const user = response.decodeJson((value: unknown) => UserSchema.parse(value));
```

Fetch resolves 4xx and 5xx responses; InnoNetwork preserves that behavior.
JSON starts as `unknown`, so a schema or caller-owned decoder must validate it.

Default headers use `defaultHeaderPolicy: "same-origin"` by default and require
a non-opaque base URL. Cross-origin requests do not receive them, and requests
that receive origin-scoped defaults use Fetch `redirect: "error"` instead of
automatically following a redirect that could propagate custom headers. Native
`redirect: "manual"` remains available. Opt into `"all"` only when every
initial and redirected destination is trusted.

## Typed endpoint

```ts
const client = new DefaultNetworkClient(session);

const getUser = {
  input: "users/42",
  init: { credentials: "include" },
  decode: (response) => response.decodeJson(UserSchema.parse),
} satisfies APIDefinition<User>;

const user = await client.request(getUser);
```

## React lifecycle

The package has no React dependency. Components own cancellation where they own
the request lifecycle:

```tsx
useEffect(() => {
  const controller = new AbortController();
  void session.data("users/42", { signal: controller.signal })
    .then((response) => response.requireSuccessful())
    .then((response) => {
      if (!controller.signal.aborted) setUser(response.decodeJson(decodeUser));
    })
    .catch((error: unknown) => {
      if (!controller.signal.aborted && !(error instanceof NetworkError && error.kind === "cancelled")) {
        reportError(error);
      }
    });
  return () => controller.abort();
}, [session, decodeUser]);
```

## Streaming and response ceilings

`data()` buffers at most 10 MiB by default. `open()` returns the native response
for caller-owned streaming:

```ts
const response = await session.open("events", { signal });
const reader = response.body?.getReader();
```

`maxResponseBodyBytes: null` disables the library ceiling but does not make an
unbounded response safe.

The ceiling measures bytes exposed by Fetch after decompression. Compressed
wire length is not a decoded-size estimate; HEAD/204/205/304 representation
headers do not imply a response body. Size failures cancel the stream without
waiting indefinitely for cleanup. Injected Fetch implementations must honor
their native `AbortSignal`; pre-aborted and late-resolved responses are also
rejected by the session. Async decoders preserve `AbortError` as cancellation
and cannot return a result after their request is aborted.

A native `Request` with a body retains Fetch's one-shot semantics. Construct a
fresh request/body for another invocation. The client does not replay requests
or automatically retry mutations.

## Browser security boundary

The wrapper cannot bypass CORS or CSP. Credentials, CSRF protection,
authorization, cookie policy, and secret storage retain native browser/server
semantics. Values shipped in frontend code remain public. Error messages redact
URL credentials and query values.

## Build and release-candidate verification

```bash
npm ci --ignore-scripts --no-audit
npm run check
npm test
npm run build
npm pack --dry-run
npm run test:browser
npm run test:browsers
```

`Scripts/check_web_public_api.sh` freezes emitted declarations and
`Scripts/check_web_tarball_consumer.sh` installs, compiles, and runs the actual
tarball outside the source package in DOM and Node-only TypeScript projects.
CI covers Node 22, 24, and 26; Chromium, Firefox, WebKit, and React lifecycle
checks run on Node 24. Install browser engines explicitly through Playwright
before running browser tests. The [readiness record](../RELEASE_READINESS.md)
identifies actual local evidence and environment limitations. Registry
provenance remains a publication operation.
