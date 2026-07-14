#if Macros
/// Authentication requirement declared by ``APIDefinition(method:path:auth:)``.
///
/// Authentication is intentionally explicit at every macro call site. A
/// request that accidentally defaults to public access can cross a security
/// boundary, so the macro does not infer this value from configuration or
/// interceptor presence.
public enum APIAuthentication: Sendable {
    /// The endpoint can execute without a configured refresh-token policy.
    case `public`

    /// The endpoint requires the authenticated execution preflight.
    case required
}

/// Derives boilerplate ``APIDefinition`` conformance for a request type.
///
/// The macro generates an extension that conforms the annotated type to
/// ``APIDefinition`` and synthesizes protocol witnesses while preserving the
/// endpoint contract on the annotated struct:
///
/// - A stored `body` or `query` property derives `Parameter` and `parameters`.
/// - An explicit `Parameter` + `parameters` pair remains authoritative for
///   advanced endpoints.
/// - Endpoints without either shape derive `Parameter = EmptyParameter`.
/// - `auth: .required` derives `Auth = AuthRequiredScope`.
///
/// The macro never synthesizes `APIResponse`; callers must keep that type
/// alias visible on the annotated type. It also leaves headers, interceptors,
/// transport, decoding, and policy overrides entirely explicit.
///
/// - Parameters:
///   - method: HTTP method expression returned by the generated `method`
///     property.
///   - path: Static route template. Placeholders such as `{id}` are expanded
///     only when they match **stored** properties declared directly on the
///     annotated type. Computed properties and members inherited from a
///     superclass or extension are not considered. Wrap dynamic values into a
///     stored property first if you need them in the path.
///   - auth: Explicit authentication requirement. Callers must choose
///     `.public` or `.required`; the macro never guesses this policy.
@attached(
    extension,
    conformances: APIDefinition,
    names: named(Parameter), named(Auth), named(parameters), named(method), named(path)
)
public macro APIDefinition(
    method: HTTPMethod,
    path: String,
    auth: APIAuthentication
) =
    #externalMacro(module: "InnoNetworkMacros", type: "APIDefinitionMacro")
#endif
