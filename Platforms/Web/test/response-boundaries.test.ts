import { describe, expect, it } from "vitest";
import { DefaultNetworkClient, FetchNetworkSession } from "../src/index.js";

describe("buffered response boundaries", () => {
  it.each([200, 304])("does not apply representation length to a bodyless %i response", async (status) => {
    const session = new FetchNetworkSession({
      maxResponseBodyBytes: 2,
      fetch: async () => new Response(null, { status, headers: { "Content-Length": "99999" } }),
    });

    const response = await session.data("https://example.com/resource", { method: "HEAD" });

    expect(response.body.byteLength).toBe(0);
    expect(response.status).toBe(status);
  });

  it("bounds decoded bytes instead of the compressed representation length", async () => {
    const session = new FetchNetworkSession({
      maxResponseBodyBytes: 2,
      fetch: async () => new Response("ok", {
        headers: { "Content-Encoding": "gzip", "Content-Length": "22" },
      }),
    });

    expect((await session.data("https://example.com/compressed")).text()).toBe("ok");
  });

  it("handles browsers that expose a non-null empty HEAD stream", async () => {
    let cancelled = false;
    const session = new FetchNetworkSession({
      maxResponseBodyBytes: 2,
      fetch: async () => new Response(new ReadableStream({ cancel() { cancelled = true; } }), {
        headers: { "Content-Length": "99999" },
      }),
    });

    expect((await session.data("https://example.com/head", { method: "HEAD" })).body.byteLength).toBe(0);
    expect(cancelled).toBe(true);
  });

  it("still rejects decoded compression expansion above the ceiling", async () => {
    const session = new FetchNetworkSession({
      maxResponseBodyBytes: 2,
      fetch: async () => new Response("expanded", {
        headers: { "Content-Encoding": "gzip", "Content-Length": "1" },
      }),
    });

    await expect(session.data("https://example.com/compressed")).rejects.toMatchObject({
      kind: "response-too-large",
    });
  });

  it.each([true, false])("settles a size failure without waiting for cleanup (declared=%s)", async (declared) => {
    let cancelled = false;
    const body = new ReadableStream<Uint8Array>({
      start(controller) { controller.enqueue(Uint8Array.of(1, 2, 3)); },
      cancel() {
        cancelled = true;
        return new Promise<void>(() => { /* Deliberately uncooperative transport cleanup. */ });
      },
    });
    const session = new FetchNetworkSession({
      maxResponseBodyBytes: 2,
      fetch: async () => new Response(body, declared ? { headers: { "Content-Length": "3" } } : {}),
    });
    const operation = session.data("https://example.com/large").then(
      () => "unexpected-success",
      (error: unknown) => error,
    );
    let timer: ReturnType<typeof setTimeout> | undefined;
    try {
      const result = await Promise.race([
        operation,
        new Promise<string>((resolve) => { timer = setTimeout(() => resolve("still-pending"), 100); }),
      ]);
      expect(result).toMatchObject({ kind: "response-too-large" });
      expect(cancelled).toBe(true);
      expect(body.locked).toBe(false);
    } finally {
      clearTimeout(timer);
    }
  });

  it("does not call an injected fetch for an already aborted request", async () => {
    let called = false;
    const session = new FetchNetworkSession({
      fetch: async () => { called = true; return new Response("late"); },
    });
    const controller = new AbortController();
    controller.abort("cancelled-before-dispatch");

    await expect(session.data("https://example.com/pre-aborted", { signal: controller.signal }))
      .rejects.toMatchObject({ kind: "cancelled" });
    expect(called).toBe(false);
  });

  it("cancels a late response if an injected fetch resolves after abort", async () => {
    const controller = new AbortController();
    let cancelled = false;
    const session = new FetchNetworkSession({
      fetch: async () => {
        controller.abort();
        return new Response(new ReadableStream({ cancel() { cancelled = true; } }));
      },
    });

    await expect(session.open("https://example.com/late", { signal: controller.signal }))
      .rejects.toMatchObject({ kind: "cancelled" });
    expect(cancelled).toBe(true);
  });

  it("preserves an asynchronous endpoint decoder's AbortError as cancellation", async () => {
    const client = new DefaultNetworkClient(new FetchNetworkSession({ fetch: async () => new Response("ok") }));

    await expect(client.request({
      input: "https://example.com/decode",
      async decode() { throw new DOMException("cancelled", "AbortError"); },
    })).rejects.toMatchObject({ kind: "cancelled" });
  });

  it("rejects a decoded result if its request is aborted during decoding", async () => {
    const controller = new AbortController();
    const client = new DefaultNetworkClient(new FetchNetworkSession({ fetch: async () => new Response("ok") }));

    await expect(client.request({
      input: "https://example.com/decode",
      init: { signal: controller.signal },
      async decode() { controller.abort(); return "obsolete"; },
    })).rejects.toMatchObject({ kind: "cancelled" });
  });
});
