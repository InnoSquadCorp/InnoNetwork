# Preserved JSON and the 6.0 validation subset

`PreservedJSON`, `PreservedJSONCoding`, `JSONSchema`, `JSONProcessingLimits`, and
`JSONProcessingError` are Provisionally Stable, opt-in contracts. Existing JSON
transports and the Stable `@APIDefinition` macro are unchanged by this foundation.
Generator integration adds `RequestEncodingPolicy.preservedJSON(limits:)` for
body-capable methods. Existing `.json` behavior is unchanged. The custom response
transport now wraps unexpected decoding errors with response context, preserving
explicit `NetworkError` and `CancellationError` values.

## Wire fidelity

`PreservedJSON(data:)` retains the exact UTF-8 bytes, including unknown fields,
whitespace, escapes and number tokens beyond Double or Decimal precision/range.
It accepts one strict JSON value. Duplicate keys (including Swift's canonically
equivalent Unicode keys), invalid UTF-8, unpaired surrogates and malformed numbers
fail. Equality is byte equality, not structural or numeric equality.

`PreservedJSONCoding.decode` / `encode` bridge Codable models containing preserved
documents, including nested arrays and objects. Non-preserved model fields use
normal Swift Codable representation and can lose unknown fields by design. A
preserved subtree retains its own bytes; surrounding model key ordering and
whitespace are not preserved. Foundation codecs intentionally throw
`unsupportedCoder` on preserved documents: they cannot expose original numeric
tokens to Decodable. There is no silent Double/Decimal fallback.

`document.decode(View.self, using:)` is an explicitly lossy application-owned
typed view. Foundation numeric ranges, rounding and coding strategies apply to
that view only; its creation cannot mutate the preserved document or establish
schema validity. The dedicated bridge supports default keys, InnoNetwork formatted Date,
base64 Data and Foundation URL/Decimal handling, not custom coding strategies.

## Bounded validation

The runtime subset covers object properties, independent required names,
allow/deny unknown properties, homogeneous arrays, strings, booleans, numbers,
mathematical integers, nullability and anyOf. Integer checks compare decimal
digits/exponents without converting to machine numbers or expanding powers of ten.
`matchingAlternatives` returns every matching index, throws on zero matches, and
does not turn a work-limit failure into a mismatch. Every branch is inspected
before validation. Generator integration must reject unsupported constraints;
the runtime enum does not claim full JSON Schema compliance.

Default limits: 1 MiB input/output, depth 64, 100,000 parsed values, 100,000 work
units per codec call or schema validation. Hard ceilings: 16 MiB, depth 128,
1,000,000 values/work units. Validation shares its budget across schema inspection
and every alternative. Codec traversal also bounds recursive container calls;
output is byte-limited while writing and parsed again to enforce nested raw-value
depth/node limits. Application-provided Codable implementations executing their
own unbounded work outside the codec are not sandboxed.

Array/object encoding accumulates reference-backed containers to avoid copying
the entire growing collection on every insertion. Errors in `JSONProcessingError`
carry no body content or property names. User-provided codecs/views and their
errors are application-owned diagnostic surfaces.

## Specification and evidence

The strict grammar follows [RFC 8259](https://www.rfc-editor.org/rfc/rfc8259).
The generator subset uses the [OpenAPI 3.0 Schema Object](https://spec.openapis.org/oas/v3.0.3.html#schema-object),
not the complete 3.1 dialect. Nullable-required and multiple-match semantics are
tested separately from successful Codable decoding.

2026-09-28 fresh evidence at `e53ec95`: 15 focused tests cover exact numeric/unknown-field
roundtrips, invalid input, duplicate/Unicode boundaries, zero/one/multiple matches,
integer mathematics, limits, nested Codable containers, ordinary scalar controls,
unsupported codecs, recursive container limits and 10,000-element accumulation.
They also cover canonical dates in mixed models, failed unkeyed-read retry and
repeated nested encoding-container reuse, with Foundation passing controls.
The generated runtime fixture covers nested anyOf, canonical dates and exact
request-body bytes. See `OPENAPI_EXPANSION_EXECUTION.md` for final-candidate local
verification and the still-separate remote/device/service acceptance gates.

## Generated anyOf usage

```swift
let choice = try Choice(json: PreservedJSON(data: receivedBytes))
let allMatches = choice.matchingBranches
let identifierView = try choice.asBranch0() // nil when branch 0 did not match
let wireBytes = try PreservedJSONCoding.encode(choice)
```

JSON and match sets are immutable: changes require a new validated wrapper.
Typed views never replace its wire representation. Use the generated endpoint
or dedicated codec, not ordinary `JSONEncoder`. Generated defaults use the limits
above; custom lower transport limits can reject an otherwise valid document.
