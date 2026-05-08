import InnoNetwork

/// Derives boilerplate ``APIDefinition`` conformance for a request type.
///
/// The macro generates an extension that conforms the annotated type to
/// ``APIDefinition`` and synthesizes `Parameter = EmptyParameter`, `method`,
/// and `path`. It does not synthesize `APIResponse`; callers must declare that
/// type alias on the annotated type.
///
/// - Parameters:
///   - method: HTTP method expression returned by the generated `method`
///     property.
///   - path: Static route template. Placeholders such as `{id}` are expanded
///     only when they match **stored** properties declared directly on the
///     annotated type. Computed properties and members inherited from a
///     superclass or extension are not considered. Wrap dynamic values into a
///     stored property first if you need them in the path.
@attached(
    extension,
    conformances: APIDefinition,
    names: named(Parameter), named(method), named(path)
)
public macro APIDefinition(method: HTTPMethod, path: String) =
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
///     ``AuthRequiredScope/self`` or ``PublicAuthScope/self``).
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
