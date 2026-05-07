import Foundation

// MARK: - Forward-compatibility aliases for the upcoming 5.0 rename
//
// 4.x ships these aliases without deprecation warnings so that
// adopters can migrate at their own pace. The 5.0 release will
// promote the new names to primary declarations and demote the old
// names to `@available(*, deprecated)` aliases that resolve back to
// the new types. The legacy aliases will then ride out a
// deprecation cycle through the 5.x line and be removed in 6.0.
//
// This file deliberately introduces only typealiases — no semantic
// or layout changes — so the symbol graph stays additive.

/// Forward-compatibility alias for ``EndpointShape``.
///
/// The 5.0 release will rename `EndpointShape` to `Endpoint` so the
/// primary endpoint protocol matches the surrounding vocabulary
/// (``EndpointAuthScope`` becomes ``AuthScope``,
/// ``ScopedEndpoint`` becomes ``EndpointBuilder``). New code can
/// adopt `Endpoint` today; existing `EndpointShape` references will
/// keep compiling through 5.x.
public typealias Endpoint = EndpointShape

/// Forward-compatibility alias for ``EndpointAuthScope``.
///
/// The 5.0 release will rename `EndpointAuthScope` to `AuthScope`.
/// The two existing concrete scopes (``PublicAuthScope`` and
/// ``AuthRequiredScope``) keep their names — only the marker
/// protocol is renamed.
public typealias AuthScope = EndpointAuthScope

/// Forward-compatibility alias for ``ScopedEndpoint``.
///
/// The 5.0 release will rename `ScopedEndpoint` to `EndpointBuilder`
/// to mirror the builder pattern it implements. The generic
/// signature (response decodable + auth scope marker) is preserved.
public typealias EndpointBuilder<Response: Decodable & Sendable, AuthScope: EndpointAuthScope> =
    ScopedEndpoint<Response, AuthScope>
