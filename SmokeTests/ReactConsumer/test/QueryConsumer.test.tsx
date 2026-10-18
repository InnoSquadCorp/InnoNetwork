import { cleanup, render, screen, waitFor } from "@testing-library/react";
import { QueryClient, QueryClientProvider, useQuery } from "@tanstack/react-query";
import { afterEach, describe, expect, it, vi } from "vitest";
import {
  DefaultNetworkClient,
  FetchNetworkSession,
  HttpStatusError,
  type FetchFunction,
  type NetworkClient,
} from "@innosquad/innonetwork";
import { messageQueryOptions } from "../src/messageQueryOptions.js";

const input = "https://api.example.com/message";

afterEach(cleanup);

function QueryMessage({ client }: { readonly client: NetworkClient }) {
  const result = useQuery(messageQueryOptions(client, input));
  return <output>{result.data ?? result.status}</output>;
}

describe("TanStack Query consumer boundary", () => {
  it("renders a typed query without a transport-specific provider or hook", async () => {
    const queryClient = new QueryClient();
    const client = new DefaultNetworkClient(new FetchNetworkSession({ fetch: async () => new Response('"hello"') }));
    try {
      const view = render(<QueryClientProvider client={queryClient}><QueryMessage client={client} /></QueryClientProvider>);
      await waitFor(() => expect(screen.getByText("hello")).toBeDefined());
      view.unmount();
    } finally {
      queryClient.clear();
    }
  });

  it("lets Query own deduplication and freshness", async () => {
    const queryClient = new QueryClient();
    const fetch = vi.fn<FetchFunction>(async () => new Response('"cached"'));
    const client = new DefaultNetworkClient(new FetchNetworkSession({ fetch }));
    try {
      const options = messageQueryOptions(client, input);
      expect(await Promise.all([queryClient.fetchQuery(options), queryClient.fetchQuery(options)]))
        .toEqual(["cached", "cached"]);
      expect(await queryClient.fetchQuery(options)).toBe("cached");
      expect(fetch).toHaveBeenCalledTimes(1);
    } finally {
      queryClient.clear();
    }
  });

  it("forwards Query's cancellation signal to native Fetch on unmount", async () => {
    const queryClient = new QueryClient();
    let signal: AbortSignal | undefined;
    const fetch: FetchFunction = async (request) => {
      if (!(request instanceof Request)) throw new TypeError("expected Request");
      signal = request.signal;
      return new Promise<Response>((_resolve, reject) => {
        request.signal.addEventListener("abort", () => reject(new DOMException("aborted", "AbortError")), { once: true });
      });
    };
    const client = new DefaultNetworkClient(new FetchNetworkSession({ fetch }));
    try {
      const view = render(<QueryClientProvider client={queryClient}><QueryMessage client={client} /></QueryClientProvider>);
      await waitFor(() => expect(signal).toBeDefined());
      view.unmount();
      await waitFor(() => expect(signal?.aborted).toBe(true));
      expect(queryClient.getQueryData(messageQueryOptions(client, input).queryKey)).toBeUndefined();
    } finally {
      queryClient.clear();
    }
  });

  it("rejects HTTP failures for Query and does not add hidden retries", async () => {
    const queryClient = new QueryClient();
    const fetch = vi.fn<FetchFunction>(async () => new Response('"denied"', { status: 401 }));
    const client = new DefaultNetworkClient(new FetchNetworkSession({ fetch }));
    try {
      await expect(queryClient.fetchQuery(messageQueryOptions(client, input))).rejects.toBeInstanceOf(HttpStatusError);
      expect(fetch).toHaveBeenCalledTimes(1);
    } finally {
      queryClient.clear();
    }
  });
});
