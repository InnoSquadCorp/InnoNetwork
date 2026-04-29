//
//  EmptyResponse.swift
//  Network
//
//  Created by Chang Woo Son on 6/20/24.
//

import Foundation

public struct EmptyResponse: HTTPEmptyResponseDecodable {
    public init() {}

    public init(from decoder: Decoder) throws {}

    public static func emptyResponseValue() -> Self {
        Self()
    }
}
