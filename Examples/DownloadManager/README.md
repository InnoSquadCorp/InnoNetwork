# DownloadManagerSample

Minimal CLI sample that fetches a remote file through
`InnoNetworkDownload`. Exercises the current exponential-backoff source
surface (`exponentialBackoff`, `retryJitterRatio`, `maxRetryDelay`) plus the
`events(for:)` AsyncStream for progress / state / completion / failure
reporting.

## Running

The sample gates real network I/O behind an environment variable so
`swift build` stays offline-safe in CI:

```bash
# Build only (no network call)
swift build

# Run against the default endpoint (proof.ovh.net/files/1Mb.dat):
INNONETWORK_RUN_INTEGRATION=1 swift run DownloadManagerSample

# Override the URL and destination:
INNONETWORK_RUN_INTEGRATION=1 swift run DownloadManagerSample \
    https://example.com/file.zip /tmp/out.zip
```

Progress is printed per integer percentage to keep log volume
reasonable. The sample `exit(0)`s on `.completed`, `exit(1)`s on
`.failed` or unexpected event-stream closure, `exit(2)`s on argument
parse errors, and `exit(0)`s (with a guidance note) when
`INNONETWORK_RUN_INTEGRATION` is unset.

## Configuration

The sample constructs its configuration via
`DownloadConfiguration.advanced { ... }` with exponential backoff
enabled:

- `retryDelay = 1.0` — base delay
- `exponentialBackoff = true`
- `retryJitterRatio = 0.2`
- `maxRetryDelay = 60` — cap in seconds (set to `<= 0` to disable)

See `EventDeliveryPolicy.md` for event-buffer tuning guidance. Treat
exponential-backoff tuning knobs as future-candidate API until they are
explicitly promoted in the stability contract.

## Troubleshooting

If the default endpoint is unreachable, any public HTTPS URL works as a
substitute — e.g. `https://proof.ovh.net/files/1Mb.dat`.
