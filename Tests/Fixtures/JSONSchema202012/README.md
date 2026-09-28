# Pinned upstream fixtures

JSON Schema Test Suite draft2020-12 files, commit
`5b0ee1613e45fcc2bddac00e07c19cd49b00d8a8`, retrieved 2026-09-28.
Source: https://github.com/json-schema-org/JSON-Schema-Test-Suite
The upstream MIT license is included as `LICENSE`.
The only source normalization is removal of trailing whitespace in required.json;
no test data, schemas, expected results, or cases are changed.

All cases in these 18 files execute; no per-case skips. They cover the selected
keyword milestone, not the entire upstream suite. References, patterns and
generator/transport integration additionally have repository-owned fixtures.
Unsupported keywords/vocabularies are documented separately, not reported as
passing upstream tests. Input/expected values retain exact JSON numeric lexemes.
