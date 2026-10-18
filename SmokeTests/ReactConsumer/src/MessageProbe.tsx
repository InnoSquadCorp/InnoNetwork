import { useEffect } from "react";
import {
  NetworkError,
  type APIDefinition,
  type NetworkClient,
  type NetworkInput,
} from "@innosquad/innonetwork";

export interface MessageProbeProps {
  readonly client: NetworkClient;
  readonly input: NetworkInput;
  readonly onMessage: (message: string) => void;
  readonly onError?: (error: unknown) => void;
}

/** Consumer-owned React lifecycle adapter; the InnoNetwork package remains React-free. */
export function MessageProbe({
  client,
  input,
  onMessage,
  onError,
}: MessageProbeProps): null {
  useEffect(() => {
    const controller = new AbortController();
    const endpoint = {
      input,
      init: { signal: controller.signal },
      decode(response) {
        return response.decodeJson((value: unknown) => {
          if (typeof value !== "string") {
            throw new TypeError("message must be a string");
          }
          return value;
        });
      },
    } satisfies APIDefinition<string>;

    void client
      .request(endpoint)
      .then((message) => {
        if (!controller.signal.aborted) {
          onMessage(message);
        }
      })
      .catch((error: unknown) => {
        if (error instanceof NetworkError && error.kind === "cancelled") {
          return;
        }
        if (!controller.signal.aborted) {
          onError?.(error);
        }
      });

    return () => controller.abort();
  }, [client, input, onError, onMessage]);

  return null;
}
