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
Both keyed `superDecoder` overloads supply null for an absent superclass key,
matching Foundation JSONDecoder; ordinary missing-key decoding still throws.

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

Encoding also admits the aggregate live intermediate representation against
`maximumBytes`: raw buffers, escaped object keys and structural delimiters.
Replacing a keyed value releases its charge when its last container/encoder
handle is released; reusing a nested container does not charge it twice.
An oversized intermediate state fails even if a later overwrite could have made
the final output smaller. Resource failure is sticky for that encoding call.
This is not a peak-RSS contract: Foundation scalar temporaries, Swift container
overhead, the final output copy and application allocations are not counted.

Array/object encoding accumulates reference-backed containers to avoid copying
the entire growing collection on every insertion. Errors in `JSONProcessingError`
carry no body content or property names. User-provided codecs/views and their
errors are application-owned diagnostic surfaces.

## Specification and evidence

### Compiled constraint plans

`JSONSchemaPlan` adds exact semantic enum equality; numeric minimum/maximum,
OpenAPI 3.0 exclusive boolean bounds, positive multipleOf; and min/max string,
array and property counts. String lengths and equality use Unicode code points,
not Swift graphemes or canonical equivalence. Numbers are decimal digit sequences
with compressed signed exponents; work exhaustion throws without rounding.
Enum equality ignores object order, whitespace and equivalent number spellings.
Each immutable plan can be used concurrently with independent validation budgets.
Compilation has a separate aggregate byte/work budget. Unreachable definitions
count against input bytes; unsupported reachable keywords fail compilation.

The generator uses these same plans for constrained component graphs. They are
preserved wrappers with throwing initialization, rather than unchecked mutable
Swift properties. Constrained operation bodies must reference named components.
Typed views remain explicit, potentially lossy projections. The standalone tool
depends on the local core product (macros disabled) to avoid a second validator;
this adds no dependency to the runtime library.

JSON and JSON-compatible YAML retain numeric lexemes. YAML aliases, merge keys,
custom scalar tags and non-JSON numbers (hexadecimal, infinity, NaN) are rejected.
No silent conversion through binary floating point occurs.

### Bounded pattern subset

Compiled `pattern` uses Unicode scalar matching and unanchored search, with
optional leading `^` and trailing `$`. Supported syntax: literal characters,
dot (except ECMAScript line terminators), positive/negative character classes
and ranges, `*`, `+`, `?`, `{m}`, `{m,n}`, `{m,}`, `\d`/`\D`, `\w`/`\W`, escaped
syntax characters and `\n`/`\r`/`\t`/`\f`/`\v`. Negated shorthand classes inside
brackets, groups, alternation, backreferences, lookaround, Unicode/property
escapes, flags and lazy quantifiers are not supported and fail compilation.
Use literal Unicode characters (JSON escapes are decoded before regex parsing).
This is an explicit ECMA-262 Unicode-mode subset, not ICU or full ECMAScript.

The engine uses non-backtracking state sets, at most 4,096 states, and the shared
validation-work budget for every transition/class test. A timeout is not the
resource control. Unsupported patterns in nonmatching branches still fail
compilation. `format` is a string annotation only in compiled plans; it does not
assert email/date/URI validity or transform the preserved wire value.

### Local recursion

Plans compile named local references to stable integer identities in an immutable
graph. Property/item edges consume an instance child and may recurse. Reference/
anyOf cycles that make no instance progress are rejected at compilation, even if
another alternative could match. Validation tracks active schema/instance pairs
and shares depth/work limits across all branches. Independent calls have no
shared mutable evaluator state.

Generated recursive components use preserved wrappers, avoiding infinitely sized
Swift value types. A static `Result` caches each immutable plan; initialization
errors remain throwing, not force-try crashes. External/file references and
unresolved or malformed local pointers are rejected without IO.

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
