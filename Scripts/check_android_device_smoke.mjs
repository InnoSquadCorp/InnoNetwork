import assert from "node:assert/strict";
import { execFileSync, spawn } from "node:child_process";
import { randomUUID } from "node:crypto";
import { once } from "node:events";
import { access } from "node:fs/promises";
import { homedir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { createInterface } from "node:readline";
import { setTimeout as delay } from "node:timers/promises";
import { fileURLToPath } from "node:url";

const repositoryRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const serial = process.argv[2];
assert.ok(serial, "Usage: node Scripts/check_android_device_smoke.mjs <adb-serial>");
const sdk = process.env.ANDROID_HOME ?? join(homedir(), "Library", "Android", "sdk");
const adb = process.env.ADB ?? join(sdk, "platform-tools", "adb");
const packageName = "com.innosquad.innonetwork.runtimesmoke";
const apk = join(repositoryRoot, "SmokeTests/AndroidConsumer/runtime/build/outputs/apk/release/runtime-release.apk");
await access(apk);
const android = (...args) => execFileSync(adb, ["-s", serial, ...args], {
  encoding: "utf8", timeout: 30_000,
});
const sdkVersion = Number(android("shell", "getprop", "ro.build.version.sdk").trim());
assert.ok(sdkVersion >= 21, `Expected Android API 21+, received ${sdkVersion}`);

const server = spawn(process.execPath, [join(repositoryRoot, "Scripts/serve_web_browser_smoke.mjs"), "0"], {
  cwd: repositoryRoot, stdio: ["ignore", "pipe", "inherit"],
});
let port;
let installed = false;
try {
  const baseUrl = await new Promise((resolveReady, rejectReady) => {
    const lines = createInterface({ input: server.stdout });
    const timer = setTimeout(() => finish(new Error("Android HTTP fixture timed out")), 10_000);
    const onExit = () => finish(new Error("Android HTTP fixture exited before readiness"));
    const finish = (error, url) => {
      clearTimeout(timer);
      server.off("exit", onExit);
      lines.close();
      if (error) rejectReady(error); else resolveReady(url);
    };
    server.once("exit", onExit);
    lines.on("line", (line) => { if (line.startsWith("READY ")) finish(undefined, line.slice(6)); });
  });
  port = new URL(baseUrl).port;
  android("reverse", `tcp:${port}`, `tcp:${port}`);
  android("install", "-r", apk);
  installed = true;
  const runID = randomUUID();
  android("shell", "am", "start", "-W", "-S", "-n", `${packageName}/.SmokeActivity`,
    "--es", "run-id", runID, "--es", "base-url", baseUrl);
  const deadline = Date.now() + 20_000;
  let logs = "";
  while (Date.now() < deadline) {
    logs = android("logcat", "-d", "-s", "InnoNetworkSmoke:I", "*:S");
    if (logs.includes(`${runID} FAILED`)) throw new Error(logs);
    if (logs.includes(`${runID} OK:`)) {
      console.log(`InnoNetwork Android API ${sdkVersion} R8 runtime: OK`);
      break;
    }
    await delay(250);
  }
  assert.ok(logs.includes(`${runID} OK:`), `Android smoke did not complete. ${logs}`);
} finally {
  for (const args of [
    ...(installed ? [["uninstall", packageName]] : []),
    ...(port !== undefined ? [["reverse", "--remove", `tcp:${port}`]] : []),
  ]) {
    try {
      android(...args);
    } catch (error) {
      // Continue releasing other task-owned resources even if a device disconnects.
      console.error("Android smoke cleanup failed:", error.message);
      process.exitCode = 1;
    }
  }
  if (server.exitCode === null) {
    const exited = once(server, "exit");
    server.kill("SIGTERM");
    await exited;
  }
}
