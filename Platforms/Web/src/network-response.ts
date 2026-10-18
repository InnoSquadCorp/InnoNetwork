import { HttpStatusError, NetworkError, isAbortError, urlForErrorMessage } from "./network-error.js";

/** Runtime validator or decoder for an untrusted JSON value. */
export type JsonDecoder<T> = (value: unknown) => T;

/** Explicit constructor contract for test fakes and custom sessions. */
export interface NetworkDataResponseInit {
  readonly request: Request;
  readonly url: string;
  readonly status: number;
  readonly statusText: string;
  readonly headers: Headers;
  readonly redirected: boolean;
  readonly responseType: Response["type"];
  readonly body: Uint8Array;
}

/** Native response metadata plus a fully buffered body. */
export class NetworkDataResponse {
  public readonly request: Request;
  public readonly url: string;
  public readonly status: number;
  public readonly statusText: string;
  public readonly redirected: boolean;
  public readonly responseType: Response["type"];
  readonly #headers: Headers;
  readonly #body: Uint8Array;

  public constructor(init: NetworkDataResponseInit) {
    this.request = init.request;
    this.url = init.url;
    this.status = init.status;
    this.statusText = init.statusText;
    this.#headers = new Headers(init.headers);
    this.redirected = init.redirected;
    this.responseType = init.responseType;
    this.#body = init.body.slice();
  }

  /** Returns an isolated copy of the buffered response headers. */
  public get headers(): Headers {
    return new Headers(this.#headers);
  }

  /** Returns an isolated copy of the buffered response body. */
  public get body(): Uint8Array {
    return this.#body.slice();
  }

  /** Whether the status is in the inclusive 200...299 range. */
  public get isSuccessful(): boolean {
    return this.status >= 200 && this.status <= 299;
  }

  /** Decodes the buffered body with the supplied text decoder. */
  public text(decoder: InstanceType<typeof TextDecoder> = new TextDecoder()): string {
    return decoder.decode(this.#body);
  }

  /** Parses the response as untrusted JSON. */
  public json(): unknown {
    try {
      const value: unknown = JSON.parse(this.text());
      return value;
    } catch (error: unknown) {
      throw new NetworkError(
        "decoding",
        `Invalid JSON response from ${urlForErrorMessage(this.url)}`,
        { cause: error },
      );
    }
  }

  /** Parses JSON and validates it with a caller-owned runtime decoder. */
  public decodeJson<T>(decoder: JsonDecoder<T>): T {
    const value = this.json();
    try {
      return decoder(value);
    } catch (error: unknown) {
      if (error instanceof NetworkError) {
        throw error;
      }
      if (isAbortError(error)) {
        throw new NetworkError("cancelled", `Request cancelled for ${urlForErrorMessage(this.url)}`, {
          cause: error,
        });
      }
      throw new NetworkError(
        "decoding",
        `JSON validation failed for ${urlForErrorMessage(this.url)}`,
        { cause: error },
      );
    }
  }

  /** Returns this response or throws `HttpStatusError` for a non-2xx status. */
  public requireSuccessful(): this {
    if (!this.isSuccessful) {
      throw new HttpStatusError(this);
    }
    return this;
  }
}
