import {
  DefaultNetworkClient,
  FetchNetworkSession,
  NetworkError,
  type APIDefinition,
} from "@innosquad/innonetwork";

const client = new DefaultNetworkClient(
  new FetchNetworkSession({ baseUrl: "https://api.example.com/v1/" }),
);

export async function loadMessage(signal: AbortSignal): Promise<string> {
  const endpoint = {
    input: "message",
    init: { signal },
    decode(response) {
      return response.decodeJson((value: unknown) => {
        if (typeof value !== "string") {
          throw new TypeError("message must be a string");
        }
        return value;
      });
    },
  } satisfies APIDefinition<string>;

  try {
    return await client.request(endpoint);
  } catch (error: unknown) {
    if (error instanceof NetworkError && error.kind === "cancelled") {
      return "cancelled";
    }
    throw error;
  }
}
