import { queryOptions } from "@tanstack/react-query";
import { type APIDefinition, type NetworkClient } from "@innosquad/innonetwork";

/** Consumer-owned query adapter. Cache keys, freshness, and retries belong to the application. */
export function messageQueryOptions(client: NetworkClient, input: string) {
  return queryOptions({
    queryKey: ["message", input] as const,
    queryFn: ({ signal }) => client.request({
      input,
      init: { signal },
      decode: (response) => response.decodeJson((value: unknown) => {
        if (typeof value !== "string") throw new TypeError("message must be a string");
        return value;
      }),
    } satisfies APIDefinition<string>),
    // No replay policy is implied by the transport; decide it per endpoint in the app.
    retry: false,
    staleTime: Infinity,
  });
}
