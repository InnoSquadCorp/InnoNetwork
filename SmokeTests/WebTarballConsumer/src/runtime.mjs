import assert from "node:assert/strict";
import {
  FetchNetworkSession,
  NetworkDataResponse,
} from "@innosquad/innonetwork";

const observedRequests = [];
const session = new FetchNetworkSession({
  baseUrl: "https://api.example.com/v1/",
  defaultHeaders: { Authorization: "Bearer package-smoke" },
  fetch: async (input) => {
    assert(input instanceof Request);
    observedRequests.push(input);
    return new Response('"package-ok"', {
      headers: { "Content-Type": "application/json" },
    });
  },
});

const sameOrigin = await session.data("status");
assert.equal(sameOrigin.decodeJson((value) => {
  assert.equal(typeof value, "string");
  return value;
}), "package-ok");
await session.data("https://other.example/status");

assert.equal(observedRequests[0].headers.get("Authorization"), "Bearer package-smoke");
assert.equal(observedRequests[1].headers.get("Authorization"), null);

const initBody = Uint8Array.of(1, 2, 3);
const immutableResponse = new NetworkDataResponse({
  request: new Request("https://api.example.com/v1/data"),
  url: "https://api.example.com/v1/data",
  status: 200,
  statusText: "OK",
  headers: new Headers({ "X-Package": "smoke" }),
  redirected: false,
  responseType: "default",
  body: initBody,
});
const exposedBody = immutableResponse.body;
exposedBody[0] = 9;
assert.deepEqual([...immutableResponse.body], [1, 2, 3]);

console.log("Web 1.0.0 installed tarball runtime: OK");
