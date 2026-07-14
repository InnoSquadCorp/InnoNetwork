# ``InnoNetworkAuthAWS``

`InnoNetworkAuthAWS` provides a reference AWS Signature Version 4 signer,
not a replacement for the AWS SDK. It is intentionally limited to single-shot,
stable data and file request bodies so application teams can validate one
signing path without pulling AWS-specific policy into the core `InnoNetwork`
product.

## Use the signer

```swift
import InnoNetworkAuthAWS

let signer = AWSSigV4Interceptor(
    accessKeyID: accessKeyID,
    secretAccessKey: secretAccessKey,
    region: "us-east-1",
    service: "execute-api"
)

let configuration = NetworkConfiguration.advanced(
    baseURL: apiURL,
    auth: AuthPack(additionalSigners: [signer])
)
```

The signer runs after request encoding, interceptors, and token refresh so its
signature covers the final URL, headers, and encoded payload sent by the
transport. File bodies are signed from the stable execution snapshot prepared
for that request.

## Scope

The signer supports normal header-based SigV4 for empty, data-backed, and
stable file-backed request bodies. Streaming SigV4 payload signing, presigned
URLs, credential provider chains, automatic rotation, and service-specific AWS
SDK behaviour are out of scope.

`AWSSigV4Interceptor` is exported only by this product. Import
`InnoNetworkAuthAWS` in files that construct the signer, or qualify the symbol
as `InnoNetworkAuthAWS.AWSSigV4Interceptor` when another module defines a type
with the same name.

## Topics

### Signing

- ``AWSSigV4Interceptor``
