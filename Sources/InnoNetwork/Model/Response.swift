//
//  Response.swift
//  Network
//
//  Created by Chang Woo Son on 6/20/24.
//

import Foundation

public struct Response: CustomDebugStringConvertible, Equatable, Sendable {

    /// The status code of the response.
    public let statusCode: Int

    /// The response data.
    public let data: Data

    /// The original URLRequest for the response.
    public let request: URLRequest?

    /// The HTTPURLResponse object.
    public let response: HTTPURLResponse?

    public init(statusCode: Int, data: Data, request: URLRequest? = nil, response: HTTPURLResponse) {
        self.statusCode = statusCode
        self.data = data
        self.request = request
        self.response = response
    }

    /// A text description of the `Response`.
    public var description: String {
        "Status Code: \(statusCode), Data Length: \(data.count)"
    }

    /// A text description of the `Response`. Suitable for debugging.
    public var debugDescription: String { description }

    public static func == (lhs: Response, rhs: Response) -> Bool {
        lhs.statusCode == rhs.statusCode
            && lhs.data == rhs.data
            && lhs.response == rhs.response
    }

    /// Returns a copy of the response with `data` zeroed out, used by the
    /// failure-payload redaction path so callers cannot accidentally observe
    /// the raw response body when ``NetworkConfiguration/captureFailurePayload``
    /// is disabled. Status code, request, and HTTPURLResponse metadata are
    /// preserved.
    public func redactingData() -> Response {
        guard let response else { return self }
        return Response(
            statusCode: statusCode,
            data: Data(),
            request: request,
            response: response
        )
    }
}
