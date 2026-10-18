import { createReadStream } from "node:fs";
import { access, stat } from "node:fs/promises";
import { createServer } from "node:http";
import { dirname, extname, join, normalize, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { gzipSync } from "node:zlib";

const scriptDirectory = dirname(fileURLToPath(import.meta.url));
const repositoryRoot = resolve(scriptDirectory, "..");
const browserRoot = join(repositoryRoot, "SmokeTests", "BrowserConsumer");
const packageRoot = join(repositoryRoot, "Platforms", "Web", "dist");
const requestedPort = Number.parseInt(process.argv[2] ?? "4173", 10);

if (!Number.isSafeInteger(requestedPort) || requestedPort < 0 || requestedPort > 65_535) {
  throw new RangeError("Port must be an integer between 0 and 65535");
}

const contentTypes = new Map([
  [".html", "text/html; charset=utf-8"],
  [".js", "text/javascript; charset=utf-8"],
  [".map", "application/json; charset=utf-8"],
]);
let redirectRequests = 0;
let redirectTargetRequests = 0;

const redirectTarget = createServer((_request, response) => {
  redirectTargetRequests += 1;
  response.writeHead(200, { "Access-Control-Allow-Origin": "*" });
  response.end("This destination must not receive origin-scoped headers");
});
await new Promise((resolveReady, rejectReady) => {
  redirectTarget.once("error", rejectReady);
  redirectTarget.listen(0, "127.0.0.1", resolveReady);
});
const redirectAddress = redirectTarget.address();
if (redirectAddress === null || typeof redirectAddress === "string") {
  throw new Error("Redirect fixture did not expose a TCP address");
}

function sendFile(response, root, requestPath) {
  const normalizedPath = normalize(requestPath).replace(/^[/\\]+/, "");
  const filePath = resolve(root, normalizedPath);
  if (filePath !== root && !filePath.startsWith(`${root}/`)) {
    response.writeHead(404).end();
    return;
  }

  access(filePath)
    .then(() => stat(filePath))
    .then((fileStat) => {
      if (!fileStat.isFile()) {
        response.writeHead(404).end();
        return;
      }
      response.writeHead(200, {
        "Content-Type": contentTypes.get(extname(filePath)) ?? "application/octet-stream",
        "Content-Length": fileStat.size,
        "Cache-Control": "no-store",
      });
      createReadStream(filePath).pipe(response);
    })
    .catch(() => response.writeHead(404).end());
}

const server = createServer((request, response) => {
  const requestUrl = new URL(request.url ?? "/", "http://127.0.0.1");
  if (requestUrl.pathname === "/api/native-stream-control" || requestUrl.pathname === "/api/native-cache-control") {
    const body = JSON.stringify("hello from Chromium");
    response.writeHead(200, {
      "Content-Type": "application/json",
      "Cache-Control": requestUrl.pathname === "/api/native-stream-control" ? "no-store" : "no-cache",
    });
    response.write(body.slice(0, 4));
    // Separate writes exercise native stream EOF independently of InnoNetwork.
    const timer = setTimeout(() => response.end(body.slice(4)), 20);
    response.once("close", () => clearTimeout(timer));
    return;
  }
  if (requestUrl.pathname === "/api/compressed") {
    const body = gzipSync("ok");
    response.writeHead(200, {
      "Content-Type": "text/plain; charset=utf-8",
      "Content-Encoding": "gzip",
      "Content-Length": body.byteLength,
      "Cache-Control": "no-store",
    });
    response.end(body);
    return;
  }
  if (requestUrl.pathname === "/api/truncated") {
    response.writeHead(200, { "Content-Length": "9999", "Cache-Control": "no-store" });
    response.write("incomplete");
    const timer = setTimeout(() => response.destroy(), 20);
    response.once("close", () => clearTimeout(timer));
    return;
  }
  if (requestUrl.pathname === "/api/head") {
    response.writeHead(200, { "Content-Length": "99999", "Cache-Control": "no-store" });
    response.end();
    return;
  }
  if (requestUrl.pathname === "/api/message" || requestUrl.pathname === "/api/native-control") {
    const body = JSON.stringify("hello from Chromium");
    response.writeHead(200, {
      "Content-Type": "application/json; charset=utf-8",
      "Content-Length": Buffer.byteLength(body),
      "Cache-Control": "no-store",
    });
    response.end(body);
    return;
  }
  if (requestUrl.pathname === "/api/slow") {
    const timer = setTimeout(() => {
      if (!response.destroyed) {
        response.writeHead(200, { "Content-Type": "text/plain; charset=utf-8" });
        response.end("too late");
      }
    }, 750);
    response.once("close", () => clearTimeout(timer));
    return;
  }
  if (requestUrl.pathname === "/api/redirect") {
    redirectRequests += 1;
    response.writeHead(302, {
      Location: `http://127.0.0.1:${redirectAddress.port}/collect`,
      "Cache-Control": "no-store",
    });
    response.end();
    return;
  }
  if (requestUrl.pathname === "/api/stats") {
    response.writeHead(200, { "Content-Type": "application/json", "Cache-Control": "no-store" });
    response.end(JSON.stringify({ redirectRequests, redirectTargetRequests }));
    return;
  }
  if (requestUrl.pathname.startsWith("/package/")) {
    sendFile(response, packageRoot, requestUrl.pathname.slice("/package/".length));
    return;
  }
  if (requestUrl.pathname === "/" || requestUrl.pathname === "/index.html") {
    sendFile(response, browserRoot, "index.html");
    return;
  }
  response.writeHead(404).end();
});

server.listen(requestedPort, "127.0.0.1", () => {
  const address = server.address();
  if (address === null || typeof address === "string") {
    throw new Error("Browser smoke server did not expose a TCP address");
  }
  console.log(`READY http://127.0.0.1:${address.port}`);
});

for (const signal of ["SIGINT", "SIGTERM"]) {
  process.once(signal, () => {
    server.closeAllConnections();
    redirectTarget.closeAllConnections();
    server.close(() => redirectTarget.close(() => process.exit(0)));
  });
}
