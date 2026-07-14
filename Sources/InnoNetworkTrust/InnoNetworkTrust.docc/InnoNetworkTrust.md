# ``InnoNetworkTrust``

Add SPKI public-key pinning to an InnoNetwork client through an explicit trust
evaluator.

## Overview

`InnoNetworkTrust` is an optional product for applications whose threat model
requires public-key pinning. Applications that use system trust evaluation do
not need to link this module.

Create a ``PublicKeyPinningPolicy`` with the accepted `sha256/` SPKI hashes,
wrap it in ``PublicKeyPinningEvaluator``, and pass the evaluator through the
core module's `TrustPolicy.custom(_:)` case.

```swift
import InnoNetwork
import InnoNetworkTrust

let pinning = PublicKeyPinningPolicy(
    pinsByHost: [
        "api.example.com": ["sha256/BASE64_ENCODED_SPKI_HASH"]
    ],
    hostMatchingStrategy: .mostSpecificHost,
    pinScope: .leafOnly
)

let trustPolicy = TrustPolicy.custom(
    PublicKeyPinningEvaluator(policy: pinning)
)
```

Keep at least one backup pin during planned key rotation. Pinning narrows the
system trust result; it does not replace certificate-chain or hostname
validation.

## Topics

### Pinning

- ``PublicKeyPinningPolicy``
- ``PublicKeyPinningPolicy/HostMatchingStrategy``
- ``PublicKeyPinningPolicy/PinScope``
- ``PublicKeyPinningEvaluator``
