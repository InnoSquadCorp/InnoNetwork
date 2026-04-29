import InnoNetwork

/// Derives boilerplate ``APIDefinition`` conformance for a request type.
///
/// The macro requires explicit `method:` and static string `path:` arguments.
/// Path placeholders such as `{id}` are expanded only when they match stored
/// properties declared directly on the annotated type.
@attached(
    extension,
    conformances: APIDefinition,
    names: named(Parameter), named(method), named(path)
)
public macro APIDefinition(method: HTTPMethod, path: String) =
    #externalMacro(module: "InnoNetworkMacros", type: "APIDefinitionMacro")

/// Creates a fluent ``Endpoint`` expression from method, path, and response type.
///
/// The third argument must be labeled `as:` and passed a response metatype,
/// for example `#endpoint(.get, "/users", as: User.self)`.
@freestanding(expression)
public macro endpoint<Response>(
    _ method: HTTPMethod,
    _ path: String,
    as responseType: Response.Type
) -> Endpoint<Response> =
    #externalMacro(module: "InnoNetworkMacros", type: "EndpointMacro")
