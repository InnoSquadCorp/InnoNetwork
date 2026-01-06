//
//  Logger+.swift
//  Network
//
//  Created by Chang Woo Son on 6/20/24.
//

import OSLog

@available(macOS 11.0, iOS 14.0, tvOS 14.0, watchOS 7.0, *)
extension Logger {
    static let API = Logger(subsystem: "innosquad.network", category: "API")
}
