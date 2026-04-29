import InnoNetwork

/// Derives boilerplate ``APIDefinition`` conformance for a request type.
@attached(
    extension,
    conformances: APIDefinition,
    names: named(Parameter), named(method), named(path)
)
public macro APIDefinition(method: HTTPMethod, path: String) =
    #externalMacro(module: "InnoNetworkMacros", type: "APIDefinitionMacro")

/// Creates a fluent ``Endpoint`` expression from method, path, and response type.
@freestanding(expression)
public macro endpoint<Response>(
    _ method: HTTPMethod,
    _ path: String,
    as responseType: Response.Type
) -> Endpoint<Response> =
    #externalMacro(module: "InnoNetworkMacros", type: "EndpointMacro")
