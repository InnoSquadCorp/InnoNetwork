/**
 * Chromium may report ERR_ABORTED after a no-store Fetch stream reaches EOF.
 * Qualify only fully validated fixture responses, and only when an independent
 * native stream reproduced the same diagnostic in this browser invocation.
 * https://github.com/microsoft/playwright/issues/42742
 */
export function isQualifiedChromiumStreamDiagnostic({
  engineName, nativeControlFailed, url, errorText, status, cacheControl, validatedUrls,
}) {
  return engineName === "chromium" && nativeControlFailed === true &&
    errorText === "net::ERR_ABORTED" && status === 200 &&
    cacheControl === "no-store" && validatedUrls.has(url);
}
