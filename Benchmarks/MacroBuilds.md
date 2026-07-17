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

## Local Xcode smoke snapshot

The following single-repeat sample is evidence that the independent Xcode
consumer path works; it is not a performance baseline. Profile clean builds run
sequentially and can observe different package caches, so compare repeated
medians on the same runner before drawing regression conclusions.

- Captured: 2026-07-17
- Host: Apple M4 Pro (`Mac16,7`), macOS 26.5
- Toolchain: Xcode 26.6, Swift 6.3.3
- Command: `--driver xcode --repeat 1 --endpoint-counts 0,10`

| Profile | Clean | No-op incremental | One endpoint edit |
|---|---:|---:|---:|
| Core only (`traits: []`) | 23.60 s | 3.17 s | — |
| Macros, 0 endpoints | 17.11 s | 2.99 s | — |
| Macros, 10 endpoints | 16.96 s | 2.97 s | 3.37 s |
