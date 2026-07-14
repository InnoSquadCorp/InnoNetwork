import InnoNetwork

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

/// Creates a fluent ``EndpointBuilder`` expression from method, path, and response type.
///
/// The third argument must be labeled `as:` and passed a response metatype,
/// for example `#endpoint(.get, "/users", as: User.self)`. The expansion
/// returns an ``EndpointBuilder`` parameterised by ``PublicAuthScope`` —
/// callers that need the authenticated executor must use the four-argument
/// overload below and pass `scope: AuthRequiredScope.self`.
///
/// - Parameters:
///   - method: HTTP method used to create the endpoint.
///   - path: Endpoint path string.
///   - responseType: Response metatype passed with the `as:` label.
/// - Returns: A public-scope ``EndpointBuilder`` configured with `method` and
///   `path`, then converted to decode `responseType`.
@freestanding(expression)
public macro endpoint<Response: Decodable & Sendable>(
    _ method: HTTPMethod,
    _ path: String,
    as responseType: Response.Type
) -> EndpointBuilder<Response, PublicAuthScope> =
    #externalMacro(module: "InnoNetworkMacros", type: "EndpointMacro")

/// Creates a fluent ``EndpointBuilder`` expression with an explicit
/// ``AuthScope``, e.g.
/// `#endpoint(.get, "/me", as: User.self, scope: AuthRequiredScope.self)`.
///
/// Use this overload when the endpoint requires the authenticated executor
/// — passing `AuthRequiredScope.self` makes the requirement visible at the
/// type level so the executor's auth preflight cannot be bypassed via the
/// macro path.
///
/// - Parameters:
///   - method: HTTP method used to create the endpoint.
///   - path: Endpoint path string.
///   - responseType: Response metatype passed with the `as:` label.
///   - scope: Concrete ``AuthScope`` metatype (e.g.
///     `AuthRequiredScope.self` or `PublicAuthScope.self`).
/// - Returns: An ``EndpointBuilder`` parameterised by `scope` and decoding
///   `responseType`.
@freestanding(expression)
public macro endpoint<Response: Decodable & Sendable, Scope: AuthScope>(
    _ method: HTTPMethod,
    _ path: String,
    as responseType: Response.Type,
    scope: Scope.Type
) -> EndpointBuilder<Response, Scope> =
    #externalMacro(module: "InnoNetworkMacros", type: "EndpointMacro")
