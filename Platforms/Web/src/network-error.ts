import type { NetworkDataResponse } from "./network-response.js";

/** Stable categories produced by the fetch-backed transport boundary. */
export type NetworkErrorKind =
  | "cancelled"
  | "transport"
  | "response-too-large"
  | "decoding";

/** A transport, cancellation, buffering, or decoding failure. */
export class NetworkError extends Error {
  public readonly kind: NetworkErrorKind;

  public constructor(kind: NetworkErrorKind, message: string, options?: ErrorOptions) {
    super(message, options);
    this.name = "NetworkError";
    this.kind = kind;
  }
}

/** A non-2xx response explicitly rejected by `requireSuccessful()`. */
export class HttpStatusError extends Error {
  public readonly response: NetworkDataResponse;

  public constructor(response: NetworkDataResponse) {
    super(`HTTP ${response.status} for ${urlForErrorMessage(response.url)}`);
    this.name = "HttpStatusError";
    this.response = response;
  }
}

/** Keeps native URL metadata intact while omitting credentials and query values from log messages. */
export function urlForErrorMessage(rawUrl: string): string {
  try {
    const url = new URL(rawUrl);
    if (url.protocol !== "http:" && url.protocol !== "https:") {
      return `${url.protocol}<redacted>`;
    }
    return `${url.protocol}//${url.host}${url.pathname}`;
  } catch {
    return "<invalid-url>";
  }
}

/** @internal Recognizes cancellation across DOM realms and native Fetch implementations. */
export function isAbortError(error: unknown): boolean {
  return typeof error === "object" && error !== null && "name" in error && error.name === "AbortError";
}

/** @internal Applies cancellation before handing a transport or decoder result to the caller. */
export function throwIfRequestAborted(request: Request): void {
  if (request.signal.aborted) {
    throw new NetworkError("cancelled", `Request cancelled for ${urlForErrorMessage(request.url)}`, {
      cause: request.signal.reason,
    });
  }
}
