import { NetworkError, isAbortError, throwIfRequestAborted, urlForErrorMessage } from "./network-error.js";
import { NetworkDataResponse } from "./network-response.js";

/** Native fetch input accepted by a network session. */
export type NetworkInput = string | Request | URL;

/** Injectable fetch shape for browsers, workers, Node, and deterministic tests. */
export type FetchFunction = (input: NetworkInput, init?: RequestInit) => Promise<Response>;

/** URLSession-shaped buffered request boundary. */
export interface NetworkSession {
  /**
   * Executes a native fetch request and buffers its response.
   *
   * HTTP 4xx and 5xx statuses resolve normally. Call `requireSuccessful()` only when the
   * application contract defines non-2xx as an error.
   */
  data(input: NetworkInput, init?: RequestInit): Promise<NetworkDataResponse>;
}

/** Executes native Fetch requests without buffering their response bodies. */
export interface StreamingNetworkSession {
  /**
   * Returns the native response after headers arrive.
   *
   * The caller owns body consumption and cancellation through the request's `AbortSignal`.
   */
  open(input: NetworkInput, init?: RequestInit): Promise<Response>;
}

/** Construction policy for `FetchNetworkSession`. */
export interface FetchNetworkSessionOptions {
  /** Base URL used only for string inputs. Include a trailing slash for directory semantics. */
  readonly baseUrl?: string | URL;
  /** Fetch implementation. Defaults to `globalThis.fetch`. */
  readonly fetch?: FetchFunction;
  /** Headers applied before request-specific headers. */
  readonly defaultHeaders?: NonNullable<RequestInit["headers"]>;
  /**
   * Scope for `defaultHeaders`.
   *
   * The safe default applies them only to the configured base URL origin and disables automatic
   * redirect following for requests that receive them. Use `all` only when every initial and
   * redirected destination accepted by this session is trusted to receive the same headers.
   */
  readonly defaultHeaderPolicy?: "same-origin" | "all";
  /** Buffered response ceiling. Use `null` to opt into unbounded buffering. */
  readonly maxResponseBodyBytes?: number | null;
}

/** A thin, React-agnostic session backed directly by the platform Fetch API. */
export class FetchNetworkSession implements NetworkSession, StreamingNetworkSession {
  public static readonly defaultMaxResponseBodyBytes = 10 * 1024 * 1024;

  readonly #baseUrl: URL | undefined;
  readonly #fetch: FetchFunction;
  readonly #defaultHeaders: Headers;
  readonly #defaultHeaderPolicy: "same-origin" | "all";
  readonly #maxResponseBodyBytes: number | null;

  public constructor(options: FetchNetworkSessionOptions = {}) {
    this.#baseUrl = options.baseUrl === undefined ? undefined : new URL(options.baseUrl);
    this.#fetch = options.fetch ?? defaultFetch;
    this.#defaultHeaders = new Headers(options.defaultHeaders);
    this.#defaultHeaderPolicy = options.defaultHeaderPolicy ?? "same-origin";
    this.#maxResponseBodyBytes =
      options.maxResponseBodyBytes === undefined
        ? FetchNetworkSession.defaultMaxResponseBodyBytes
        : options.maxResponseBodyBytes;

    if (
      this.#defaultHeaderPolicy !== "same-origin" &&
      this.#defaultHeaderPolicy !== "all"
    ) {
      throw new TypeError("defaultHeaderPolicy must be 'same-origin' or 'all'");
    }
    if (
      this.#maxResponseBodyBytes !== null &&
      (!Number.isSafeInteger(this.#maxResponseBodyBytes) || this.#maxResponseBodyBytes < 0)
    ) {
      throw new RangeError("maxResponseBodyBytes must be a non-negative safe integer or null");
    }
    if (
      this.#defaultHeaderPolicy === "same-origin" &&
      (this.#baseUrl === undefined || this.#baseUrl.origin === "null") &&
      [...this.#defaultHeaders].length > 0
    ) {
      throw new TypeError(
        "defaultHeaders require a non-opaque baseUrl for same-origin scoping; use defaultHeaderPolicy 'all' only for trusted destinations",
      );
    }
  }

  public async data(input: NetworkInput, init?: RequestInit): Promise<NetworkDataResponse> {
    const request = this.#makeRequest(input, init);
    const response = await this.#perform(request);
    const body = await readBoundedBody(response, request, this.#maxResponseBodyBytes);
    throwIfRequestAborted(request);

    return new NetworkDataResponse({
      request,
      url: response.url || request.url,
      status: response.status,
      statusText: response.statusText,
      headers: response.headers,
      redirected: response.redirected,
      responseType: response.type,
      body,
    });
  }

  /**
   * Executes a request without buffering and returns the native `Response`.
   *
   * The caller owns streaming and body consumption. Browser CORS and CSP behavior is unchanged.
   */
  public async open(input: NetworkInput, init?: RequestInit): Promise<Response> {
    return this.#perform(this.#makeRequest(input, init));
  }

  #makeRequest(input: NetworkInput, init?: RequestInit): Request {
    const resolvedInput =
      typeof input === "string" && this.#baseUrl !== undefined
        ? new URL(input, this.#baseUrl)
        : input;
    const request = new Request(resolvedInput, init);
    if (
      [...this.#defaultHeaders].length === 0 ||
      (this.#defaultHeaderPolicy === "same-origin" &&
        (this.#baseUrl?.origin === "null" ||
          new URL(request.url).origin !== this.#baseUrl?.origin))
    ) {
      return request;
    }

    const headers = new Headers(this.#defaultHeaders);
    request.headers.forEach((value, name) => headers.set(name, value));
    const redirect =
      this.#defaultHeaderPolicy === "same-origin" && request.redirect === "follow"
        ? "error"
        : request.redirect;
    return new Request(request, { headers, redirect });
  }

  async #perform(request: Request): Promise<Response> {
    throwIfRequestAborted(request);
    try {
      const response = await this.#fetch(request);
      if (request.signal.aborted) {
        cancelResponseBody(response, "cancelled");
        throwIfRequestAborted(request);
      }
      return response;
    } catch (error: unknown) {
      if (error instanceof NetworkError) {
        throw error;
      }
      if (request.signal.aborted || isAbortError(error)) {
        throw new NetworkError("cancelled", `Request cancelled for ${urlForErrorMessage(request.url)}`, {
          cause: error,
        });
      }
      throw new NetworkError("transport", `Transport failed for ${urlForErrorMessage(request.url)}`, {
        cause: error,
      });
    }
  }
}

const defaultFetch: FetchFunction = (input, init) => globalThis.fetch(input, init);

async function readBoundedBody(
  response: Response,
  request: Request,
  maxResponseBodyBytes: number | null,
): Promise<Uint8Array> {
  if (response.body === null) {
    return new Uint8Array();
  }
  if (request.method === "HEAD" || response.status === 204 || response.status === 205 || response.status === 304) {
    // Some browsers expose an empty stream for a response that cannot carry an HTTP body.
    cancelResponseBody(response, "bodyless-response");
    return new Uint8Array();
  }

  // Native Fetch exposes decoded bytes but can retain the compressed representation's headers.
  const encoding = response.headers.get("Content-Encoding")?.trim().toLowerCase();
  const declaredBytes = encoding === undefined || encoding === "identity"
    ? parseContentLength(response.headers.get("Content-Length"))
    : undefined;
  if (
    maxResponseBodyBytes !== null &&
    declaredBytes !== undefined &&
    declaredBytes > maxResponseBodyBytes
  ) {
    cancelResponseBody(response, "response-too-large");
    throw responseTooLarge(request, maxResponseBodyBytes, declaredBytes, 0);
  }

  const blocks: Uint8Array[] = [];
  let currentBlock: Uint8Array | undefined;
  let currentBlockOffset = 0;
  let receivedBytes = 0;
  let reader: ReadableStreamDefaultReader<Uint8Array> | undefined;

  try {
    reader = response.body.getReader();
    while (true) {
      const result = await reader.read();
      if (result.done) {
        break;
      }
      const chunk = result.value;
      if (chunk.byteLength === 0) {
        continue;
      }
      receivedBytes += chunk.byteLength;
      if (maxResponseBodyBytes !== null && receivedBytes > maxResponseBodyBytes) {
        void reader.cancel("response-too-large").catch(() => {
          // Keep the deterministic size-policy failure when transport cleanup also fails.
        });
        throw responseTooLarge(
          request,
          maxResponseBodyBytes,
          declaredBytes,
          receivedBytes,
        );
      }
      let chunkOffset = 0;
      while (chunkOffset < chunk.byteLength) {
        if (currentBlock === undefined || currentBlockOffset === currentBlock.byteLength) {
          currentBlock = new Uint8Array(responseBlockSize(maxResponseBodyBytes));
          currentBlockOffset = 0;
          blocks.push(currentBlock);
        }
        const copyLength = Math.min(
          currentBlock.byteLength - currentBlockOffset,
          chunk.byteLength - chunkOffset,
        );
        currentBlock.set(chunk.subarray(chunkOffset, chunkOffset + copyLength), currentBlockOffset);
        currentBlockOffset += copyLength;
        chunkOffset += copyLength;
      }
    }
  } catch (error: unknown) {
    if (error instanceof NetworkError) {
      throw error;
    }
    if (request.signal.aborted || isAbortError(error)) {
      throw new NetworkError("cancelled", `Request cancelled for ${urlForErrorMessage(request.url)}`, {
        cause: error,
      });
    }
    throw new NetworkError("transport", `Response stream failed for ${urlForErrorMessage(request.url)}`, {
      cause: error,
    });
  } finally {
    reader?.releaseLock();
  }

  const body = new Uint8Array(receivedBytes);
  let offset = 0;
  let remainingBytes = receivedBytes;
  for (const block of blocks) {
    const copyLength = Math.min(block.byteLength, remainingBytes);
    body.set(block.subarray(0, copyLength), offset);
    offset += copyLength;
    remainingBytes -= copyLength;
  }
  return body;
}

function responseBlockSize(maxResponseBodyBytes: number | null): number {
  if (maxResponseBodyBytes === null) {
    return RESPONSE_BLOCK_BYTES;
  }
  return Math.max(1, Math.min(RESPONSE_BLOCK_BYTES, maxResponseBodyBytes));
}

function cancelResponseBody(response: Response, reason: string): void {
  void response.body?.cancel(reason).catch(() => {
    // The response is already being rejected; cleanup failure must not replace that result.
  });
}

function parseContentLength(rawValue: string | null): number | undefined {
  if (rawValue === null || !/^\d+$/.test(rawValue)) {
    return undefined;
  }
  const parsed = Number(rawValue);
  return Number.isSafeInteger(parsed) ? parsed : undefined;
}

function responseTooLarge(
  request: Request,
  limitBytes: number,
  declaredBytes: number | undefined,
  receivedBytes: number,
): NetworkError {
  const sizeDetail =
    declaredBytes === undefined
      ? `${receivedBytes} bytes received`
      : `${declaredBytes} bytes declared`;
  return new NetworkError(
    "response-too-large",
    `Response from ${urlForErrorMessage(request.url)} exceeded ${limitBytes} bytes (${sizeDetail})`,
  );
}

const RESPONSE_BLOCK_BYTES = 64 * 1024;
