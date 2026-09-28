# Compiled schema / OpenAPI 3.1 milestone

Status: Preview generator, Provisionally Stable runtime. This is a bounded
subset, **not full OpenAPI 3.1 or JSON Schema 2020-12 support**. Unknown assertions
fail compilation before generated files are written. No schema resolution uses
the network or filesystem. Core gains no third-party runtime dependency; the
offline tool reuses core with the Macros trait disabled.

| Feature | OpenAPI 3.0 plans | 2020-12 / OpenAPI 3.1 plans |
| --- | --- | --- |
| type | One object/array/string/number/integer/boolean | Also null and nonempty distinct type arrays |
| nullable | Boolean, only expands an explicit type | Rejected; use type/null |
| boolean schemas | Rejected | true / false |
| properties, required | Supported; exact code-point names | Supported |
| additionalProperties | Boolean only | Boolean only; schema-valued form rejected |
| items | One homogeneous schema | One homogeneous schema, including boolean |
| anyOf | Every matching branch; work shared | Same |
| allOf / oneOf | Existing typed object/discriminator generator, not compiled plans | Conjunction / exactly one matching schema |
| enum | Semantic JSON equality, no float conversion | Same; const also supported and conjunctive with enum |
| minimum / maximum / multipleOf | Exact decimal coefficients and compressed exponents | Same |
| exclusiveMinimum / exclusiveMaximum | Boolean modifying corresponding inclusive bound | Numeric assertions, independent of inclusive bounds |
| min/max Length, Items, Properties | Nonnegative machine-sized integer bounds | Same; strings count Unicode scalars |
| pattern | Explicit bounded ECMA-262 Unicode-mode subset | Same; see PRESERVED_JSON.md for syntax |
| format | Annotation only in compiled plans | Annotation only; no assertion vocabulary |
| local recursive refs | Named `#/components/schemas/` | Same plus root `#/$defs/`; instance-progress required |
| ref siblings | Rejected except title/description | Conjunctive validation, not ignored |
| dialect | Fixed 3.0 semantics | Explicit `jsonSchemaDialect` / `$schema` admission |
| advanced vocabularies | Unsupported | `$id`, anchors, dynamic refs, nested `$defs`, arbitrary JSON Pointer targets, unevaluated*, prefixItems, contains, uniqueItems, not/if/then/else, dependent*, content* rejected |

Recognized 3.1 dialect URIs are `https://spec.openapis.org/oas/3.1/dialect/base`
and `https://json-schema.org/draft/2020-12/schema`. They select the semantics above,
not full vocabulary coverage. Foreign/nested foreign dialects are rejected.
The API's default remains `.openAPI30`; 3.1 source is never silently read as 3.0.

## OpenAPI generator roles

The 3.1 milestone emits preserved component wrappers and GET/POST/PUT/PATCH/DELETE
endpoints with named component request/response bodies using application/json.
Existing declared simple scalar path parameters and named credential contracts
remain available. Component wrappers validate both decode and encode. Their
immutable graph is compiled once per model; typed projections are explicit and
may lose unknown fields or numeric precision without changing the wire model.

Webhooks, callbacks, path-item references, HEAD/OPTIONS/TRACE generation,
query/header/cookie parameter serialization, response headers/links, non-JSON
media, reusable non-schema components, and custom content encoding are rejected
in 3.1. Server URLs are application-owned NetworkConfiguration inputs, not chosen
from document `servers`; annotations and x- metadata do not change routing.
This generator is not a server generator or a complete OpenAPI client generator.

## Limits and compatibility

Runtime input/graph/instance limits are in `PRESERVED_JSON.md`. Schema constants
use exact numbers, but size keywords must fit nonnegative Int. Regex expansion
has a 4,096-state ceiling. Zero-progress reference/applicator cycles fail before
validation, even if a different branch could succeed. External refs never load.
Root `$defs` are supported; definition-local scope/URI rebasing is not.

Tool schema decoding paths and model-selection traversal are limited to 32
levels; ordinary typed-model normalization to 16 levels. These bounds apply
before recursive traversal can overflow a Swift worker stack, including models
constructed in code. Compiled graph validation has its independent depth/work
budget. JSON-compatible YAML numbers preserve source lexemes. YAML aliases,
merges, custom tags and non-JSON number spellings fail explicitly.

## Evidence

All 355 examples in 18 pinned official draft2020-12 files are run without skips
by `JSONSchemaOfficialTests`. See `Tests/Fixtures/JSONSchema202012/README.md` for
the upstream commit and MIT license. This covers only those files, not the
entire upstream suite. Local tests cover unsupported syntax, budgets, references,
patterns, concurrent use, codecs and dialect mixing. Generated fixtures exercise
deterministic regeneration, Swift 6 typechecking and runtime acceptance/rejection.

Sources: [JSON Schema validation](https://json-schema.org/draft/2020-12/json-schema-validation),
[core](https://json-schema.org/draft/2020-12/json-schema-core),
[OpenAPI dialect selection](https://spec.openapis.org/oas/v3.1.1.html#specifying-schema-dialects),
[official test suite](https://github.com/json-schema-org/JSON-Schema-Test-Suite).
