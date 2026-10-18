# Android API baselines

The `*.api` files are deterministic `javap` snapshots of the final release AAR and JAR
artifacts. They guard JVM-visible binary signatures, including descriptors and constants.

Run `Scripts/check_android_public_api.sh` to verify them. Use `--update` only after
reviewing a deliberate compatibility change. Kotlin explicit API mode, compiler consumer
tests, and KSP positive/negative fixtures complement this artifact-level gate.
