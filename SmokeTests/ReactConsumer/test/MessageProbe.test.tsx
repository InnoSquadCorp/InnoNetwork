import { cleanup, render, waitFor } from "@testing-library/react";
import { StrictMode } from "react";
import { afterEach, describe, expect, it, vi } from "vitest";
import {
  DefaultNetworkClient,
  FetchNetworkSession,
  type FetchFunction,
} from "@innosquad/innonetwork";
import { MessageProbe } from "../src/MessageProbe.js";

afterEach(cleanup);

describe("React consumer lifecycle", () => {
  it("decodes a typed endpoint through the React effect", async () => {
    const fetch: FetchFunction = async () => new Response('"hello"');
    const client = new DefaultNetworkClient(new FetchNetworkSession({ fetch }));
    const onMessage = vi.fn<(message: string) => void>();

    render(
      <MessageProbe
        client={client}
        input="https://api.example.com/message"
        onMessage={onMessage}
      />,
    );

    await waitFor(() => expect(onMessage).toHaveBeenCalledWith("hello"));
  });

  it("aborts an in-flight native request when the component unmounts", async () => {
    let observedSignal: AbortSignal | undefined;
    const fetch: FetchFunction = async (input) => {
      if (!(input instanceof Request)) {
        throw new TypeError("expected Request");
      }
      observedSignal = input.signal;
      return new Promise<Response>((_resolve, reject) => {
        input.signal.addEventListener(
          "abort",
          () => reject(new DOMException("aborted", "AbortError")),
          { once: true },
        );
      });
    };
    const client = new DefaultNetworkClient(new FetchNetworkSession({ fetch }));
    const onMessage = vi.fn<(message: string) => void>();
    const onError = vi.fn<(error: unknown) => void>();
    const view = render(
      <MessageProbe
        client={client}
        input="https://api.example.com/slow"
        onMessage={onMessage}
        onError={onError}
      />,
    );

    await waitFor(() => expect(observedSignal).toBeDefined());
    view.unmount();

    await waitFor(() => expect(observedSignal?.aborted).toBe(true));
    expect(onMessage).not.toHaveBeenCalled();
    expect(onError).not.toHaveBeenCalled();
  });

  it("survives StrictMode setup-cleanup-setup without delivering an obsolete result", async () => {
    const signals: AbortSignal[] = [];
    const fetch: FetchFunction = async (input) => {
      if (!(input instanceof Request)) throw new TypeError("expected Request");
      signals.push(input.signal);
      return new Response('"current"');
    };
    const client = new DefaultNetworkClient(new FetchNetworkSession({ fetch }));
    const onMessage = vi.fn<(message: string) => void>();
    const onError = vi.fn<(error: unknown) => void>();

    const view = render(<StrictMode>
      <MessageProbe client={client} input="https://api.example.com/message"
        onMessage={onMessage} onError={onError} />
    </StrictMode>);

    await waitFor(() => expect(onMessage).toHaveBeenCalledExactlyOnceWith("current"));
    expect(signals).toHaveLength(2);
    expect(signals[0]?.aborted).toBe(true);
    expect(signals[1]?.aborted).toBe(false);
    view.unmount();
    expect(signals[1]?.aborted).toBe(true);
    expect(onError).not.toHaveBeenCalled();
  });

  it("keeps the latest input when an obsolete transport resolves after replacement", async () => {
    let resolveFirst: ((response: Response) => void) | undefined;
    const fetch: FetchFunction = async (input) => {
      if (!(input instanceof Request)) throw new TypeError("expected Request");
      if (new URL(input.url).pathname === "/first") {
        return new Promise<Response>((resolve) => { resolveFirst = resolve; });
      }
      return new Response('"second"');
    };
    const client = new DefaultNetworkClient(new FetchNetworkSession({ fetch }));
    const onMessage = vi.fn<(message: string) => void>();
    const onError = vi.fn<(error: unknown) => void>();
    const view = render(<MessageProbe client={client} input="https://api.example.com/first"
      onMessage={onMessage} onError={onError} />);

    await waitFor(() => expect(resolveFirst).toBeDefined());
    view.rerender(<MessageProbe client={client} input="https://api.example.com/second"
      onMessage={onMessage} onError={onError} />);
    await waitFor(() => expect(onMessage).toHaveBeenCalledExactlyOnceWith("second"));
    resolveFirst?.(new Response('"first"'));
    await new Promise<void>((resolve) => setTimeout(resolve, 0));

    expect(onMessage).toHaveBeenCalledExactlyOnceWith("second");
    expect(onError).not.toHaveBeenCalled();
  });

  it("delivers invalid payload failures through the consumer's error boundary", async () => {
    const client = new DefaultNetworkClient(new FetchNetworkSession({ fetch: async () => new Response("42") }));
    const onMessage = vi.fn<(message: string) => void>();
    const onError = vi.fn<(error: unknown) => void>();

    render(<MessageProbe client={client} input="https://api.example.com/invalid"
      onMessage={onMessage} onError={onError} />);

    await waitFor(() => expect(onError).toHaveBeenCalledWith(expect.objectContaining({ kind: "decoding" })));
    expect(onMessage).not.toHaveBeenCalled();
  });
});
