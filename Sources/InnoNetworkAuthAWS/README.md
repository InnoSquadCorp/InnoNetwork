# InnoNetworkAuthAWS

`InnoNetworkAuthAWS` provides a reference AWS Signature Version 4 interceptor,
not a replacement for the AWS SDK. Use it when an InnoNetwork client needs
single-shot SigV4 signing for small in-memory request bodies and you can own
service validation, credential rotation, retries, and non-standard AWS flows.

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

Out of scope:

- streaming SigV4 payload signing
- presigned URLs
- credential provider chains and automatic rotation
- service-specific AWS SDK behaviours

`AWSSigV4Interceptor` is exported only by this product. Import
`InnoNetworkAuthAWS` in files that construct the signer, or qualify the symbol
as `InnoNetworkAuthAWS.AWSSigV4Interceptor` when another module defines a type
with the same name.
