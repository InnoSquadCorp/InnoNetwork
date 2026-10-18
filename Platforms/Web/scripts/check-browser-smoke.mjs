import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { once } from "node:events";
import { createInterface } from "node:readline";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { chromium, firefox, webkit } from "playwright";
import { isQualifiedChromiumStreamDiagnostic } from "./browser-network-diagnostics.mjs";

const scriptDirectory = dirname(fileURLToPath(import.meta.url));
const repositoryRoot = resolve(scriptDirectory, "../../..");
const serverScript = join(repositoryRoot, "Scripts", "serve_web_browser_smoke.mjs");
const server = spawn(process.execPath, [serverScript, "0"], {
  cwd: repositoryRoot,
  stdio: ["ignore", "pipe", "pipe"],
});

let serverErrorOutput = "";
server.stderr.setEncoding("utf8");
server.stderr.on("data", (chunk) => {
  serverErrorOutput += chunk;
});

try {
  const serverUrl = await waitForServer(server);
  const engineNames = process.argv.includes("--all")
    ? ["chromium", "firefox", "webkit"]
    : [process.env.INNO_BROWSER ?? "chromium"];
  const failures = [];
  for (const engineName of engineNames) {
    try {
      await checkBrowser(engineName, serverUrl);
    } catch (error) {
      failures.push(error);
    }
  }
  if (failures.length > 0) throw new AggregateError(failures, "Native browser validation failed");
} finally {
  if (server.exitCode === null) {
    const exited = once(server, "exit");
    server.kill("SIGTERM");
    await exited;
  }
}

async function checkBrowser(engineName, serverUrl) {
  const browserType = { chromium, firefox, webkit }[engineName];
  assert.ok(browserType, `Unknown browser: ${engineName}`);
  const channel = process.env.INNO_BROWSER_CHANNEL;
  const browser = await browserType.launch({
    headless: true,
    timeout: 30_000,
    ...(channel === undefined || engineName !== "chromium" ? {} : { channel }),
  });
  try {
    const page = await browser.newPage();
    const browserErrors = [];
    const consoleErrors = [];
    const intentionalFailures = [];
    const requestFailures = [];
    const responses = new Map();
    const networkEvents = [];
    page.on("request", (request) => networkEvents.push(`start ${request.method()} ${request.url()}`));
    page.on("response", (response) => {
      networkEvents.push(`headers ${response.status()} ${response.url()}`);
      responses.set(response.url(), { status: response.status(), cacheControl: response.headers()["cache-control"] });
    });
    page.on("requestfinished", (request) => networkEvents.push(`finished ${request.url()}`));
    const expectedFailures = new Set([
      new URL("api/slow", serverUrl).href,
      new URL("api/redirect", serverUrl).href,
      new URL("api/head", serverUrl).href,
      new URL("api/truncated", serverUrl).href,
    ]);
    page.on("console", (message) => {
      if (message.type() === "error") consoleErrors.push(message.text());
    });
    page.on("pageerror", (error) => {
      const blockedRedirect = `${new URL(serverUrl).host}/api/redirect due to access control checks.`;
      if (engineName !== "webkit" || !error.message.endsWith(blockedRedirect)) {
        browserErrors.push(`page: ${error.message}`);
      }
    });
    page.on("requestfailed", (request) => {
      networkEvents.push(`failed ${request.url()} ${request.failure()?.errorText}`);
      if (expectedFailures.has(request.url())) {
        intentionalFailures.push(request.url());
      } else {
        requestFailures.push({ url: request.url(), errorText: request.failure()?.errorText });
      }
    });

    await page.goto(serverUrl, { waitUntil: "domcontentloaded" });
    const status = page.locator("#status[data-state]");
    await status.waitFor({ timeout: 10_000 });

    assert.equal(await status.getAttribute("data-state"), "ok", await page.locator("#details").textContent());
    const details = JSON.parse((await page.locator("#details").textContent()) ?? "null");
    assert.deepEqual(details, {
      message: "hello from Chromium",
      cancellationKind: "cancelled",
      redirectKind: "transport",
      headBytes: 0,
      compressed: "ok",
      redirectTargetRequests: 0,
      nativeControls: true,
      truncatedKind: "transport",
    });
    // The page must first verify every payload and both native stream controls.
    // No arbitrary abort, failed body, non-200 status or unvalidated URL is accepted.
    const controlUrl = new URL("api/native-stream-control", serverUrl).href;
    const nativeControlFailed = requestFailures.some((failure) =>
      failure.url === controlUrl && failure.errorText === "net::ERR_ABORTED" &&
      responses.get(controlUrl)?.status === 200 && responses.get(controlUrl)?.cacheControl === "no-store");
    const validatedUrls = new Set(["api/native-stream-control", "api/message", "api/compressed", "api/stats"]
      .map((path) => new URL(path, serverUrl).href));
    const qualifiedDiagnostics = [];
    for (const failure of requestFailures) {
      const metadata = responses.get(failure.url);
      if (isQualifiedChromiumStreamDiagnostic({
        ...failure, ...metadata, engineName, nativeControlFailed, validatedUrls,
      })) {
        qualifiedDiagnostics.push(failure.url);
      } else {
        browserErrors.push(`request: ${failure.url} ${failure.errorText}`);
      }
    }
    assert.deepEqual(browserErrors, [], `Browser errors: ${JSON.stringify(browserErrors)}\n${networkEvents.join("\n")}`);
    if (qualifiedDiagnostics.length > 0) {
      console.warn(`Chromium no-store DevTools diagnostic reproduced by native Fetch; validated bodies: ${qualifiedDiagnostics.join(", ")}`);
    }
    // Engines report blocked Fetch redirects differently, sometimes without a source URL.
    // Permit only native resource messages backed by this fixture's expected failed requests.
    const webkitRedirectMessage = "Not allowed to follow a redirection while loading " + new URL("api/redirect", serverUrl).href;
    assert.deepEqual(consoleErrors.filter((message) =>
      !message.startsWith("Failed to load resource:") &&
      !(engineName === "webkit" && message === webkitRedirectMessage)), []);
    assert.ok(consoleErrors.length <= intentionalFailures.length + qualifiedDiagnostics.length, consoleErrors.join("\n"));

    console.log(`InnoNetwork ${engineName} runtime: OK (${browser.version()})`);
  } finally {
    await browser.close();
  }
}

async function waitForServer(serverProcess) {
  const lines = createInterface({ input: serverProcess.stdout });
  return new Promise((resolveUrl, rejectUrl) => {
    const timeout = setTimeout(() => {
      cleanup();
      rejectUrl(new Error(`Browser fixture server timed out. ${serverErrorOutput}`.trim()));
    }, 10_000);

    const onLine = (line) => {
      if (line.startsWith("READY ")) {
        cleanup();
        resolveUrl(line.slice("READY ".length));
      }
    };
    const onExit = (code, signal) => {
      cleanup();
      rejectUrl(
        new Error(
          `Browser fixture server exited before readiness (${code ?? signal}). ${serverErrorOutput}`.trim(),
        ),
      );
    };
    const cleanup = () => {
      clearTimeout(timeout);
      lines.off("line", onLine);
      serverProcess.off("exit", onExit);
      lines.close();
    };

    lines.on("line", onLine);
    serverProcess.once("exit", onExit);
  });
}
