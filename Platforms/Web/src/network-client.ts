import { HttpStatusError, NetworkError, isAbortError, throwIfRequestAborted, urlForErrorMessage } from "./network-error.js";
import type { NetworkDataResponse } from "./network-response.js";
import type { NetworkInput, NetworkSession } from "./network-session.js";

/** Typed request/response definition executed by `NetworkClient`. */
export interface APIDefinition<Output> {
  /** Native Fetch input. Relative strings use the session's configured base URL. */
  readonly input: NetworkInput;
  /** Native Fetch options for this request. */
  readonly init?: RequestInit;
  /** Optional endpoint-specific status policy. Defaults to 200...299. */
  acceptsStatusCode?(statusCode: number): boolean;
  /** Validates and decodes the already bounded response. */
  decode(response: NetworkDataResponse): Output | Promise<Output>;
}

/** Executes typed `APIDefinition` values. */
export interface NetworkClient {
  /** Executes, validates, and decodes one endpoint definition. */
  request<Output>(definition: APIDefinition<Output>): Promise<Output>;
}

/** Default typed client layered on the native low-level `NetworkSession`. */
export class DefaultNetworkClient implements NetworkClient {
  readonly #session: NetworkSession;

  public constructor(session: NetworkSession) {
    this.#session = session;
  }

  public async request<Output>(definition: APIDefinition<Output>): Promise<Output> {
    const response = await this.#session.data(definition.input, definition.init);
    throwIfRequestAborted(response.request);
    const isAccepted = definition.acceptsStatusCode?.(response.status) ??
      defaultAcceptsStatusCode(response.status);
    if (!isAccepted) {
      throw new HttpStatusError(response);
    }

    try {
      const output = await definition.decode(response);
      throwIfRequestAborted(response.request);
      return output;
    } catch (error: unknown) {
      if (error instanceof NetworkError) {
        throw error;
      }
      if (response.request.signal.aborted || isAbortError(error)) {
        throw new NetworkError(
          "cancelled",
          `Request cancelled for ${urlForErrorMessage(response.url)}`,
          { cause: error },
        );
      }
      throw new NetworkError(
        "decoding",
        `Failed to decode response from ${urlForErrorMessage(response.url)}`,
        { cause: error },
      );
    }
  }
}

function defaultAcceptsStatusCode(statusCode: number): boolean {
  return statusCode >= 200 && statusCode <= 299;
}
