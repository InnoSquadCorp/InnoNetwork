# Query Encoding Reference

`URLQueryEncoder` flattens nested objects and arrays into URL query items. This page
documents the exact serialization rules so consumers can pick a server-side router that
matches, or shape their request models when their server expects a different convention.

## Encoding rules

| Input shape | Output |
|-------------|--------|
| Top-level scalar (e.g. `42`) | Requires `rootKey:`; emits `rootKey=42`. Without `rootKey:` throws `URLQueryEncoder.EncodingError.unsupportedTopLevelValue`. |
| Top-level array | Same as scalar — requires `rootKey:`. |
| Top-level object | Each property becomes a query item. |
| Nested object (`{ user: { name: "kim" } }`) | `user[name]=kim` (PHP/Rails bracket notation). |
| Nested array (`{ tags: ["a", "b"] }`) | `tags[0]=a&tags[1]=b` (zero-indexed brackets). |
| Mixed (`{ filter: { ids: [1, 2] } }`) | `filter[ids][0]=1&filter[ids][1]=2`. |
| Optional / `nil` value | Skipped (no key emitted). Use an empty string if you need the key to appear. |
| `Date` value | Encoded with `dateEncodingStrategy` (defaults to ISO-8601 with fractional seconds). |
| Empty object / empty array | No query items emitted. |

Keys are sorted alphabetically inside each level so the encoded output is deterministic
across runs (important for cache-key reproducibility and snapshot-style tests).

`keyEncodingStrategy` controls only the leaf key transformation (e.g. snake_case). The
bracket structure itself is fixed.

## Comparison with OpenAPI / RFC 6570

InnoNetwork's bracket notation is **not** the OpenAPI 3 default. If your server is generated
from an OpenAPI spec, you must align the parameter `style` and `explode` values explicitly,
or shape the request model so the flat representation matches.

| Convention | Object encoding | Array encoding | Match? |
|------------|-----------------|----------------|--------|
| InnoNetwork (this library) | `user[name]=kim` | `tags[0]=a&tags[1]=b` | — |
| OpenAPI `style: form, explode: true` (default) | `name=kim` (no parent key) | `tags=a&tags=b` (repeated key) | ❌ |
| OpenAPI `style: form, explode: false` | `user=name,kim` | `tags=a,b` (csv) | ❌ |
| OpenAPI `style: deepObject, explode: true` | `user[name]=kim` | (objects only) | ✅ for objects |
| OpenAPI `style: pipeDelimited` | n/a | `tags=a\|b` | ❌ |
| RFC 6570 simple (`{?tags}`) | (objects rare) | `tags=a,b` | ❌ |
| Rails / Rack router | `user[name]=kim` | `tags[]=a&tags[]=b` (no index) | partial — Rails arrays omit the index, InnoNetwork keeps it |
| PHP `http_build_query()` | `user[name]=kim` | `tags[0]=a&tags[1]=b` | ✅ exact match |
| Spring `@RequestParam` (binder) | `user.name=kim` | `tags=a&tags=b` | ❌ |

The closest 1:1 match is **PHP `http_build_query`**. Rails and Express (with the `qs`
parser) accept the indexed-bracket form transparently, but Spring, FastAPI default,
and OpenAPI-generated clients usually do not.

## Server-side configuration tips

- **Express (Node).** Install `qs` (default in newer Express) — it supports indexed
  brackets out of the box.
- **Rails / Sinatra.** Works without changes; `params[:user][:name]` returns the value.
- **Spring.** Use `@RequestParam Map<String, String>` and parse the bracket structure
  manually, or rewrite the request model to flat keys.
- **FastAPI.** Use `Query(...)` with explicit parameter names matching the bracketed form,
  or pre-flatten on the client.
- **NGINX log analysis.** Bracket characters are percent-encoded (`%5B`, `%5D`) on the
  wire; logs show `tags%5B0%5D=a`. Decode before grepping.

## Mismatch troubleshooting

Common symptom: server returns `400` "missing parameter" or silently treats the value as
`null`. Quick diagnosis:

1. Inspect the actual sent URL via `NetworkLogger` (set `subsystem` to your bundle id, then
   filter on the request URL). Confirm the bracket form.
2. Compare against the server's parser convention table above.
3. If your server cannot accept bracket notation, flatten the request model so `URLQueryEncoder`
   emits flat keys — for example:

   ```swift
   // BEFORE — encoded as user[name]=kim
   struct Params: Encodable {
       let user: User
   }

   // AFTER — encoded as userName=kim
   struct Params: Encodable {
       let userName: String
   }
   ```

## Testing your encoding

`URLQueryEncoder` is deterministic and pure. The fastest way to verify a model's encoding
is a snapshot-style test:

```swift
import Testing
@testable import InnoNetwork

@Test
func userQueryEncoding() throws {
    struct Params: Encodable {
        let user: User
        let tags: [String]
    }
    struct User: Encodable { let name: String; let age: Int }

    let items = try URLQueryEncoder().encode(Params(
        user: User(name: "kim", age: 32),
        tags: ["new", "trial"]
    ))

    let serialized = items
        .map { "\($0.name)=\($0.value ?? "")" }
        .joined(separator: "&")

    #expect(serialized == "tags[0]=new&tags[1]=trial&user[age]=32&user[name]=kim")
}
```

Note that keys are sorted alphabetically (`tags` before `user`, `age` before `name`),
which gives the test a stable expected string regardless of source-property declaration
order.

## Related

- [`URLQueryEncoder.swift`](../Sources/InnoNetwork/URLQueryEncoder.swift) — implementation.
- [`URLQueryKeyEncodingStrategy.swift`](../Sources/InnoNetwork/URLQueryKeyEncodingStrategy.swift) —
  leaf-key transformations (snake_case, kebab-case, custom).
