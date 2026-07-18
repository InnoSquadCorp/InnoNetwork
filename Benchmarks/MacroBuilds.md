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

## Repeated local baseline

The committed 2026-07-18 baseline uses five isolated consumer builds per
profile and records the median. Each repetition starts in a new temporary
package (and a new DerivedData directory for Xcode), then performs a clean
build, a no-op incremental build, and—when endpoints exist—a one-endpoint edit.

- Source revision: `b9fffeebc1838253a74dc27f5293495a179acf8b`
- Source tree: `84ebf27ada6af702949755f845adb2b0f7f6fe69`
- Host: Apple M4 Pro, 14 cores, 48 GB; macOS 26.5 (25F71)
- Toolchain: Xcode 26.6 (17F113), Swift 6.3.3 (swiftlang-6.3.3.1.3)
- Matrix: Core-only plus macro-enabled 0, 10, 50, and 200 endpoints
- Repetitions: 5 per driver and profile
- Raw samples: [SwiftPM](MacroBuildBaselines/swiftpm-2026-07-18.json),
  [Xcode](MacroBuildBaselines/xcode-2026-07-18.json), and
  [provenance manifest](MacroBuildBaselines/manifest.json)

### SwiftPM median

| Profile | Clean | No-op incremental | One endpoint edit |
|---|---:|---:|---:|
| Core only (`traits: []`) | 15.08 s | 2.22 s | — |
| Macros, 0 endpoints | 15.34 s | 2.29 s | — |
| Macros, 10 endpoints | 15.17 s | 2.27 s | 1.05 s |
| Macros, 50 endpoints | 15.71 s | 2.35 s | 1.30 s |
| Macros, 200 endpoints | 16.68 s | 2.29 s | 2.29 s |

### Xcode median

| Profile | Clean | No-op incremental | One endpoint edit |
|---|---:|---:|---:|
| Core only (`traits: []`) | 17.48 s | 3.33 s | — |
| Macros, 0 endpoints | 17.02 s | 2.98 s | — |
| Macros, 10 endpoints | 17.54 s | 3.17 s | 3.63 s |
| Macros, 50 endpoints | 17.74 s | 3.27 s | 3.76 s |
| Macros, 200 endpoints | 18.77 s | 3.24 s | 4.77 s |

The first clean sample can include package-cache warm-up; the median is the
comparison value. These are local reference numbers, not portable absolute
thresholds. Compare only the same driver, environment, endpoint count, and
phase. Investigate a sustained same-runner median regression above 10% before
changing the baseline. Validate committed files with:

```bash
python3 Scripts/check_macro_build_baseline_contract.py
```
