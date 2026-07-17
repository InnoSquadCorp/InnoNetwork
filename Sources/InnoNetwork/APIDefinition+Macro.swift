#if Macros
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
/// - `auth:` derives the explicit ``SessionAuthentication`` witness.
///
/// The macro never synthesizes `APIResponse`; callers must keep that type
/// alias visible on the annotated type. It also leaves headers, interceptors,
/// transport, decoding, and policy overrides entirely explicit.
///
/// - Parameters:
///   - method: HTTP method expression returned by the generated `method`
///     property. Simple body/query inference accepts a standard member in
///     contextual (`.get`), type-qualified (`HTTPMethod.get`), or
///     module-qualified (`InnoNetwork.HTTPMethod.get`) form. Arbitrary aliases
///     and unrelated qualified bases are rejected because their source
///     spelling cannot prove the payload semantics.
///   - path: Single-line, non-raw static route literal. Placeholders such as
///     `{id}` are expanded only when they match **stored** properties declared
///     directly on the annotated type. Computed properties and members inherited
///     from a superclass or extension are not considered. Wrap dynamic values
///     into a stored property first if you need them in the path.
///   - auth: Explicit authentication requirement. Callers must use the
///     contextual (`.anonymous`), type-qualified
///     (`SessionAuthentication.anonymous`), or module-qualified
///     (`InnoNetwork.SessionAuthentication.anonymous`) form. The macro never
///     guesses this policy or accepts arbitrary aliases.
@attached(
    extension,
    conformances: APIDefinition,
    names: named(Parameter), named(parameters), named(method), named(path), named(sessionAuthentication)
)
public macro APIDefinition(
    method: HTTPMethod,
    path: String,
    auth: SessionAuthentication
) =
    #externalMacro(module: "InnoNetworkMacros", type: "APIDefinitionMacro")
#endif
