# InnoNetworkCodegen

> **Experimental, repository-local package.** This package is not remotely
> consumable from an InnoNetwork release tag.

`InnoNetworkCodegen` contains the optional `@APIDefinition` and `#endpoint`
macros. Keeping it in a nested package prevents root `InnoNetwork` consumers
from resolving or building `swift-syntax`.

SwiftPM loads the manifest at the root of a package repository URL. The root
manifest does not vend an `InnoNetworkCodegen` product, and SwiftPM cannot
select this nested manifest from the same release tag. The manifest also uses
`../..` as a path dependency on `InnoNetwork`, so it is intentionally supported
only from a complete local checkout of this repository. Do not add the root
repository URL and expect `product(name: "InnoNetworkCodegen", ...)` to resolve.

Remote consumption requires moving codegen to a separately distributed package
or changing the root package graph. Until then, use the macros only in local
workspace development and treat their distribution contract as experimental.

## Platform matrix

The local package follows the root package deployment floors:

- iOS 16+
- macOS 14+
- tvOS 16+
- watchOS 9+
- visionOS 1+
- Swift 6.2+

These matching floors describe source compatibility in a local checkout; they
do not make the nested package available from a remote tag.
