# TargetType Catalog

This recipe shows how to keep a Moya-style endpoint catalog while preserving
InnoNetwork's typed `APIDefinition` request/response surface.

The enum stays as the routing index:

- one case per app-level operation;
- associated values for route parameters or request body inputs;
- a `send(using:)` switch that maps each case to a concrete `APIDefinition`.

The important tradeoff is intentional: the enum does not erase the response
type before request execution. Each switch branch still calls a concrete
endpoint, receives a typed response, and wraps it in a catalog result enum for
callers that want one dispatch point.

Use this shape when migrating a TargetType-heavy codebase gradually. New code
can call the concrete `APIDefinition` values directly, while older layers keep
their central enum until they are ready to split by feature.
