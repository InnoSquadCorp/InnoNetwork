//
//  EmptyResponse.swift
//  Network
//
//  Created by Chang Woo Son on 6/20/24.
//

import Foundation


public struct EmptyResponse: Decodable, Sendable {
    public init() {}
    
    public init(from decoder: Decoder) throws {}
}
