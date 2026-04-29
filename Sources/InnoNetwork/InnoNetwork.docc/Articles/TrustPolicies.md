# Trust policies

Configure TLS trust evaluation explicitly so a misconfigured certificate cannot silently
become a security bug.

## Overview

``TrustPolicy`` decides what counts as a trustworthy server certificate chain. The default
``TrustPolicy/systemDefault`` delegates to the OS — fine for most apps. Production clients
that hold sensitive credentials or transact value should consider public-key pinning.

## Policies

| Policy | When to use |
|--------|-------------|
| ``TrustPolicy/systemDefault`` | Any host that follows public CA distribution. The OS trust store is the source of truth. |
| ``TrustPolicy/publicKeyPinning(_:)`` | High-risk hosts where you want defence-in-depth against a compromised CA issuing for your domain. |
| ``TrustPolicy/custom(_:)`` | Bespoke evaluation (corporate roots, time-bound exceptions, or layered checks). Implements ``TrustEvaluating``. |

## Public-key pinning

Pin the leaf or intermediate's public key (not the certificate itself). Public keys survive
certificate rotation as long as you reuse the same key material.

```swift
let pinning = PublicKeyPinningPolicy(
    pinsByHost: [
        "api.example.com": [
            "sha256/AAAAB3NzaC1yc2E...currentKey...",
            "sha256/AAAAB3NzaC1yc2E...nextKey...",  // pre-published rollover key
        ],
    ],
    includesSubdomains: false,
    allowDefaultEvaluationForUnpinnedHosts: false,
    hostMatchingStrategy: .mostSpecificHost
)

let configuration = NetworkConfiguration.advanced(
    baseURL: URL(string: "https://api.example.com/v1")!
) { builder in
    builder.trustPolicy = .publicKeyPinning(pinning)
}
```

### Rotation policy

- **Always ship at least two pins.** Current operational key + next planned key. The day
  the server rotates, the client validates instantly.
- **Set up a calendar reminder for cert renewal.** A pin-mismatch failure has no automatic
  recovery — every install of your app stops talking to the API until you ship an update.
- **Plan an unpinned escape hatch.** Feature flag or a fallback `.systemDefault` route for
  emergency recovery, if you can tolerate the brief reduction in security posture.

### Choosing which key to pin

Pin the **server's leaf key** for tightest control, **or** an intermediate CA's key for
operational flexibility. Pinning the leaf means rotation requires a coordinated client +
server update; pinning the intermediate means you can rotate leaf certificates without
client updates as long as the intermediate stays the same.

### Host matching

The default host matching strategy, ``PublicKeyPinningPolicy/HostMatchingStrategy/unionAllMatches``,
preserves the original behavior: if both `api.example.com` and `example.com`
match a request host, their pin sets are unioned. Choose
``PublicKeyPinningPolicy/HostMatchingStrategy/mostSpecificHost`` when parent
and subdomain pins must be operationally isolated. With that strategy, exact
host pins win; otherwise only the longest matching parent-domain pins are used.

## Custom evaluation

For evaluators that need full chain inspection, time-of-day rules, or fallback to
`.systemDefault` based on context, implement ``TrustEvaluating`` directly:

```swift
struct CorporateRootTrust: TrustEvaluating {
    let corporateRoot: SecCertificate

    func evaluate(challenge: URLAuthenticationChallenge) -> Bool {
        guard let serverTrust = challenge.protectionSpace.serverTrust else {
            return false
        }

        // Append the corporate root to the trust object before delegating to the OS.
        let host = challenge.protectionSpace.host
        let policies = [SecPolicyCreateSSL(true, host as CFString)]
        SecTrustSetPolicies(serverTrust, policies as CFTypeRef)
        SecTrustSetAnchorCertificates(serverTrust, [corporateRoot] as CFArray)
        SecTrustSetAnchorCertificatesOnly(serverTrust, true)

        return SecTrustEvaluateWithError(serverTrust, nil)
    }
}
```

A `false` result turns into ``NetworkError/trustEvaluationFailed(_:)`` — surface it to the user
and do not auto-retry.

## What pinning does not protect against

- A compromised endpoint that the server itself is willing to send.
- Logic bugs in the server (auth bypass, IDOR, etc.).
- Rooted/jailbroken devices where attackers can patch the binary.
- Same-process MITM via debugger attachment in development builds.

Pinning narrows the attack surface but is not a substitute for end-to-end auth and proper
server-side controls.

## Related

- ``TrustPolicy``
- ``TrustEvaluating``
- ``NetworkError/trustEvaluationFailed(_:)``
