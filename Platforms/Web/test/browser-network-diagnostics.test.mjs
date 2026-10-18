import { describe, expect, it } from "vitest";
import { isQualifiedChromiumStreamDiagnostic } from "../scripts/browser-network-diagnostics.mjs";

const baseline = {
  engineName: "chromium",
  nativeControlFailed: true,
  url: "http://127.0.0.1:1234/api/message",
  errorText: "net::ERR_ABORTED",
  status: 200,
  cacheControl: "no-store",
  validatedUrls: new Set(["http://127.0.0.1:1234/api/message"]),
};

describe("browser diagnostic qualification", () => {
  it("qualifies only the reproduced diagnostic on a validated complete body", () => {
    expect(isQualifiedChromiumStreamDiagnostic(baseline)).toBe(true);
  });

  it.each([
    { engineName: "firefox" },
    { nativeControlFailed: false },
    { url: "http://127.0.0.1:1234/api/unvalidated" },
    { errorText: "net::ERR_CONNECTION_RESET" },
    { status: 500 },
    { cacheControl: "no-cache" },
    { validatedUrls: new Set() },
  ])("keeps an unmatched failure blocking: %j", (override) => {
    expect(isQualifiedChromiumStreamDiagnostic({ ...baseline, ...override })).toBe(false);
  });
});
