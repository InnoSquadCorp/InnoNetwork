import { describe, expect, it } from "vitest";
import {
  DefaultNetworkClient,
  FetchNetworkSession,
  HttpStatusError,
  NetworkDataResponse,
  NetworkError,
  type FetchFunction,
  type APIDefinition,
} from "../src/index.js";

describe("FetchNetworkSession", () => {
  it("uses native Request semantics and preserves HTTP failures as responses", async () => {
    let observedRequest: Request | undefined;
    const fetch: FetchFunction = async (input) => {
      if (!(input instanceof Request)) {
        throw new TypeError("expected Request");
      }
      observedRequest = input;
      return new Response("missing", {
        status: 404,
        headers: { "Content-Type": "text/plain; charset=utf-8" },
      });
    };
    const session = new FetchNetworkSession({
      baseUrl: "https://api.example.com/v1/",
      defaultHeaders: { "X-Client": "InnoNetwork" },
      fetch,
    });

    const response = await session.data("users/42?token=secret", {
      headers: { "X-Request-ID": "request-1" },
    });

    expect(response.status).toBe(404);
    expect(response.isSuccessful).toBe(false);
    expect(response.text()).toBe("missing");
    expect(observedRequest?.url).toBe("https://api.example.com/v1/users/42?token=secret");
    expect(observedRequest?.headers.get("X-Client")).toBe("InnoNetwork");
    expect(observedRequest?.headers.get("X-Request-ID")).toBe("request-1");
    expect(() => response.requireSuccessful()).toThrow(HttpStatusError);
    expect(() => response.requireSuccessful()).toThrowError(
      "HTTP 404 for https://api.example.com/v1/users/42",
    );
  });

  it("scopes default headers to the configured base URL origin", async () => {
    const requests: Request[] = [];
    const fetch: FetchFunction = async (input) => {
      if (!(input instanceof Request)) {
        throw new TypeError("expected Request");
      }
      requests.push(input);
      return new Response("ok");
    };
    const session = new FetchNetworkSession({
      baseUrl: "https://api.example.com/v1/",
      defaultHeaders: {
        Authorization: "Bearer secret",
        "X-Client": "InnoNetwork",
      },
      fetch,
    });

    await session.data("users/42", { headers: { "X-Client": "request" } });
    await session.data("https://attacker.example/collect");
    await session.data(new URL("https://attacker.example/url"));
    await session.data(new Request("https://attacker.example/request"));

    expect(requests[0]?.headers.get("Authorization")).toBe("Bearer secret");
    expect(requests[0]?.headers.get("X-Client")).toBe("request");
    expect(requests[0]?.redirect).toBe("error");
    for (const request of requests.slice(1)) {
      expect(request.headers.get("Authorization")).toBeNull();
      expect(request.headers.get("X-Client")).toBeNull();
      expect(request.redirect).toBe("follow");
    }
  });

  it("requires an explicit all-destinations policy for unscoped default headers", async () => {
    expect(
      () => new FetchNetworkSession({ defaultHeaders: { Authorization: "Bearer secret" } }),
    ).toThrowError(/require a non-opaque baseUrl/);

    let observedRequest: Request | undefined;
    const session = new FetchNetworkSession({
      defaultHeaders: { Authorization: "Bearer trusted" },
      defaultHeaderPolicy: "all",
      fetch: async (input) => {
        if (!(input instanceof Request)) {
          throw new TypeError("expected Request");
        }
        observedRequest = input;
        return new Response("ok");
      },
    });

    await session.data("https://trusted.example/resource");

    expect(observedRequest?.headers.get("Authorization")).toBe("Bearer trusted");
    expect(observedRequest?.redirect).toBe("follow");
  });

  it("preserves caller-owned manual redirect handling with origin-scoped defaults", async () => {
    let observedRequest: Request | undefined;
    const session = new FetchNetworkSession({
      baseUrl: "https://api.example.com/",
      defaultHeaders: { "X-Guard": "value" },
      fetch: async (input) => {
        if (!(input instanceof Request)) {
          throw new TypeError("expected Request");
        }
        observedRequest = input;
        return new Response(null, { status: 302, headers: { Location: "/next" } });
      },
    });

    await session.open("redirect", { redirect: "manual" });

    expect(observedRequest?.headers.get("X-Guard")).toBe("value");
    expect(observedRequest?.redirect).toBe("manual");
  });

  it("rejects invalid and opaque default-header policies at the JavaScript boundary", () => {
    expect(
      () =>
        new FetchNetworkSession({
          defaultHeaderPolicy: "unexpected" as "same-origin",
        }),
    ).toThrowError("defaultHeaderPolicy must be 'same-origin' or 'all'");

    expect(
      () =>
        new FetchNetworkSession({
          baseUrl: "data:text/plain,base",
          defaultHeaders: { Authorization: "Bearer secret" },
        }),
    ).toThrowError(/non-opaque baseUrl/);
  });

  it("rejects a declared response larger than the configured ceiling", async () => {
    const fetch: FetchFunction = async () =>
      new Response("12345", { headers: { "Content-Length": "5" } });
    const session = new FetchNetworkSession({ fetch, maxResponseBodyBytes: 4 });

    await expect(session.data("https://example.com/large")).rejects.toMatchObject({
      kind: "response-too-large",
    });
  });

  it("propagates AbortSignal cancellation as a typed network error", async () => {
    const fetch: FetchFunction = async (input) => {
      if (!(input instanceof Request)) {
        throw new TypeError("expected Request");
      }
      return new Promise<Response>((_resolve, reject) => {
        input.signal.addEventListener(
          "abort",
          () => reject(new DOMException("aborted", "AbortError")),
          { once: true },
        );
      });
    };
    const session = new FetchNetworkSession({ fetch });
    const controller = new AbortController();

    const operation = session.data("https://example.com/slow", {
      signal: controller.signal,
    });
    controller.abort();

    await expect(operation).rejects.toEqual(
      expect.objectContaining<Partial<NetworkError>>({ kind: "cancelled" }),
    );
  });

  it("propagates cancellation while buffering the response body", async () => {
    const fetch: FetchFunction = async (input) => {
      if (!(input instanceof Request)) {
        throw new TypeError("expected Request");
      }
      const body = new ReadableStream<Uint8Array>({
        start(controller) {
          input.signal.addEventListener(
            "abort",
            () => controller.error(new DOMException("aborted", "AbortError")),
            { once: true },
          );
        },
      });
      return new Response(body);
    };
    const session = new FetchNetworkSession({ fetch });
    const controller = new AbortController();

    const operation = session.data("https://example.com/slow-body", {
      signal: controller.signal,
    });
    controller.abort();

    await expect(operation).rejects.toEqual(
      expect.objectContaining<Partial<NetworkError>>({ kind: "cancelled" }),
    );
  });

  it("buffers adversarial one-byte stream chunks through bounded owned blocks", async () => {
    const byteCount = 65_537;
    let emitted = 0;
    const body = new ReadableStream<Uint8Array>({
      pull(controller) {
        if (emitted === byteCount) {
          controller.close();
          return;
        }
        controller.enqueue(Uint8Array.of(emitted % 251));
        emitted += 1;
      },
    });
    const session = new FetchNetworkSession({
      maxResponseBodyBytes: byteCount,
      fetch: async () => new Response(body),
    });

    const response = await session.data("https://example.com/fragmented");

    expect(response.body.byteLength).toBe(byteCount);
    expect(response.body[0]).toBe(0);
    expect(response.body[byteCount - 1]).toBe((byteCount - 1) % 251);
  });

  it("maps response stream acquisition failures to a typed transport error", async () => {
    const response = new Response(new ReadableStream<Uint8Array>());
    const heldReader = response.body?.getReader();
    const fetch: FetchFunction = async () => response;
    const session = new FetchNetworkSession({ fetch });

    try {
      await expect(
        session.data("https://example.com/locked?token=secret"),
      ).rejects.toMatchObject({
        kind: "transport",
        message: "Response stream failed for https://example.com/locked",
      });
    } finally {
      heldReader?.releaseLock();
    }
  });

  it("parses JSON as unknown and requires caller-owned validation", async () => {
    const fetch: FetchFunction = async () =>
      new Response('{"id":"user-1","ignored":true}', {
        headers: { "Content-Type": "application/json" },
      });
    const session = new FetchNetworkSession({ fetch });
    const response = await session.data("https://example.com/user");

    const user = response.decodeJson((value: unknown) => {
      if (
        typeof value !== "object" ||
        value === null ||
        !("id" in value) ||
        typeof value.id !== "string"
      ) {
        throw new TypeError("invalid user");
      }
      return { id: value.id };
    });

    expect(user).toEqual({ id: "user-1" });
  });

  it("redacts query values from JSON decoding failures", async () => {
    const fetch: FetchFunction = async () => new Response("not-json");
    const session = new FetchNetworkSession({ fetch });
    const response = await session.data("https://example.com/user?token=secret");

    expect(() => response.json()).toThrowError(
      "Invalid JSON response from https://example.com/user",
    );
    expect(() => response.json()).not.toThrowError(/secret/);
  });

  it("keeps buffered body and headers isolated from caller mutation", () => {
    const inputBody = Uint8Array.of(1, 2, 3);
    const inputHeaders = new Headers({ "X-Value": "original" });
    const response = new NetworkDataResponse({
      request: new Request("https://example.com/data"),
      url: "https://example.com/data",
      status: 200,
      statusText: "OK",
      headers: inputHeaders,
      redirected: false,
      responseType: "default",
      body: inputBody,
    });

    inputBody[0] = 9;
    inputHeaders.set("X-Value", "changed");
    const exposedBody = response.body;
    exposedBody[1] = 9;
    const exposedHeaders = response.headers;
    exposedHeaders.set("X-Value", "changed-again");

    expect([...response.body]).toEqual([1, 2, 3]);
    expect(response.headers.get("X-Value")).toBe("original");
  });

  it("uses a deterministic redacted message for malformed fake response URLs", () => {
    const response = new NetworkDataResponse({
      request: new Request("https://example.com/data"),
      url: "not a URL?token=secret",
      status: 200,
      statusText: "OK",
      headers: new Headers(),
      redirected: false,
      responseType: "default",
      body: new TextEncoder().encode("not-json"),
    });

    expect(() => response.json()).toThrowError("Invalid JSON response from <invalid-url>");
    expect(() => response.json()).not.toThrowError(/secret/);
  });

  it("keeps raw streaming available through open", async () => {
    const fetch: FetchFunction = async () => new Response("stream-me");
    const session = new FetchNetworkSession({ fetch, maxResponseBodyBytes: 1 });

    const response = await session.open("https://example.com/stream");

    expect(await response.text()).toBe("stream-me");
  });

  it("executes and decodes a typed API definition", async () => {
    const fetch: FetchFunction = async () =>
      new Response('{"id":"user-1"}', {
        headers: { "Content-Type": "application/json" },
      });
    const client = new DefaultNetworkClient(
      new FetchNetworkSession({
        baseUrl: "https://api.example.com/v1/",
        fetch,
      }),
    );
    const endpoint = {
      input: "users/1",
      decode(response) {
        return response.decodeJson((value: unknown) => {
          if (
            typeof value !== "object" ||
            value === null ||
            !("id" in value) ||
            typeof value.id !== "string"
          ) {
            throw new TypeError("invalid user");
          }
          return { id: value.id };
        });
      },
    } satisfies APIDefinition<{ id: string }>;

    await expect(client.request(endpoint)).resolves.toEqual({ id: "user-1" });
  });

  it("validates endpoint status before invoking its decoder", async () => {
    const fetch: FetchFunction = async () => new Response("missing", { status: 404 });
    const client = new DefaultNetworkClient(new FetchNetworkSession({ fetch }));
    let decoded = false;
    const endpoint = {
      input: "https://api.example.com/missing",
      decode() {
        decoded = true;
        return "unexpected";
      },
    } satisfies APIDefinition<string>;

    await expect(client.request(endpoint)).rejects.toBeInstanceOf(HttpStatusError);
    expect(decoded).toBe(false);
  });

  it("allows an endpoint-specific non-2xx status policy", async () => {
    const fetch: FetchFunction = async () => new Response("missing", { status: 404 });
    const client = new DefaultNetworkClient(new FetchNetworkSession({ fetch }));
    const endpoint = {
      input: "https://api.example.com/optional",
      acceptsStatusCode: (statusCode: number) => statusCode === 404,
      decode: (response) => response.text(),
    } satisfies APIDefinition<string>;

    await expect(client.request(endpoint)).resolves.toBe("missing");
  });
});
