import Foundation

// Split out of `DownloadManager.swift` so the watchdog poll loop and its
// stall-detection heuristics live next to each other rather than being
// interleaved with unrelated lifecycle / event-handling code. All methods
// stay actor-isolated; this file only relocates code, no behaviour changes.
extension DownloadManager {

    func startInactivityWatchdog(timeout: Duration) {
        guard !isShutdown, inactivityWatchdogTask == nil else { return }
        inactivityWatchdogTask = Task { [weak self] in
            await self?.runInactivityWatchdog(timeout: timeout)
        }
    }

    func runInactivityWatchdog(timeout: Duration) async {
        // Poll at half the timeout so worst-case detection latency is
        // bounded by `timeout * 1.5` for any stall.
        let cadence = max(Duration.milliseconds(50), timeout / 2)
        while !Task.isCancelled, !isShutdown {
            do {
                try await Task.sleep(for: cadence)
            } catch {
                return
            }
            if Task.isCancelled || isShutdown { return }
            await cancelInactiveDownloads(timeout: timeout)
        }
    }

    func cancelInactiveDownloads(timeout: Duration) async {
        let now = ContinuousClock().now
        let tasks = await runtimeRegistry.allTasks()
        for task in tasks {
            guard await task.state == .downloading else { continue }
            // Seed `lastProgressAt` lazily on first observation of a
            // `.downloading` task that has never reported progress. This
            // covers the "server accepted the connection but never sends
            // bytes" case — the most common real-world stall — so the
            // watchdog measures from "first observed downloading" rather
            // than refusing to fire because no progress arrived.
            let lastProgress: ContinuousClock.Instant
            if let observed = await task.lastProgressAt {
                lastProgress = observed
            } else {
                await task.setLastProgressAt(now)
                continue
            }
            if now - lastProgress > timeout {
                // Re-check state right before cancel: the task may have
                // raced to `.paused` / `.completed` / `.failed` across the
                // `lastProgressAt` await above.
                guard await task.state == .downloading else { continue }
                Self.logger.notice(
                    "Cancelling stalled download \(task.id, privacy: .private(mask: .hash)) — no progress for \(String(describing: timeout), privacy: .public)"
                )
                await cancel(task)
            }
        }
    }
}
