# Macro Consumer Build Measurements

`Scripts/measure_macro_builds.py` measures the package from an independent
consumer rather than timing the macro target in isolation. It covers:

- Core-only consumption with `traits: []`;
- macro-enabled consumption with 0, 10, 50, and 200 endpoint declarations;
- clean, no-op incremental, and one-endpoint-edit builds; and
- SwiftPM and Xcode build drivers.

Run a quick local sample:

```bash
python3 Scripts/measure_macro_builds.py \
  --repeat 1 \
  --endpoint-counts 0,10 \
  --json-path .build/macro-builds/local.json
```

Capture the full SwiftPM and Xcode matrices before a release:

```bash
python3 Scripts/measure_macro_builds.py \
  --driver swiftpm \
  --json-path .build/macro-builds/swiftpm.json

python3 Scripts/measure_macro_builds.py \
  --driver xcode \
  --json-path .build/macro-builds/xcode.json
```

The committed script intentionally has no absolute-time release threshold.
Hosted and developer machines differ materially. Establish a same-runner
baseline first, then review a sustained median regression above 10%. Macro
source edit timing is measured in the package's normal build gate; this
consumer harness never touches the checked-out library source while running.
