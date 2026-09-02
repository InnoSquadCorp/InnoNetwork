# FairPlay acceptance gate

This isolated test package is an opt-in, physical-iOS-device acceptance harness for
`InnoNetworkHLSAVFoundation`. It deliberately contains no FairPlay
certificate, content identifier, authorization value, key material, or KSM
policy. The harness requires iOS 17 or newer because it executes through the
Swift Testing runtime; the shipping library retains its iOS 16 deployment
floor.

Run it through `Scripts/run_fairplay_acceptance.sh` from the repository root.
The script forwards FairPlay acceptance material through test-runner
environment values instead of build settings and requires FairPlay protocol
version 3. Certificate and KSM endpoints must return success directly;
redirects fail closed. The KSM URL must be an application-owned adapter that
accepts raw SPC bytes in an `application/octet-stream` POST and returns raw CKC
bytes in a successful HTTPS response. It receives these contextual headers:

- `X-InnoNetwork-FairPlay-Key-ID`
- `X-InnoNetwork-FairPlay-Request-Purpose` (`initial` or `renewal`)
- `Authorization`, when the matching optional environment value is set

The first test accepts an initial SPC v3 response, asks AVFoundation for an
explicit renewal, and waits for both system success callbacks. The second
downloads a protected `.movpkg`, creates and stores a persistable key, then
recreates both the FairPlay session and test key store. Playback must advance
from the local package while a rejecting transport proves that reopening made
no KSM request. The acceptance asset must use the configured single FairPlay
key; multi-key fixture policy belongs to the application-owned harness.

Apple FairPlay development credentials are insufficient for this gate because
they do not work with Apple devices. Use an SDK 26 application certificate and
matching production acceptance environment. The app remains responsible for
its production KSM adapter, credential loading, secure key-store schema,
entitlement policy, and deletion lifecycle.
