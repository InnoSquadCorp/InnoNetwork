//
//  Encodable+.swift
//  Network
//
//  Created by Chang Woo Son on 5/4/24.
//

import Foundation


extension Encodable {
    var dictionary: [String: Any]? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data, options: .allowFragments)).flatMap { $0 as? [String: Any] }
    }

    var encodedQueryItems: [URLQueryItem] {
        guard let dict = dictionary else { return [] }
        return dict.flatMap { key, value -> [URLQueryItem] in
            encodeQueryValue(key: key, value: value)
        }
    }

    var jsonData: Data? {
        try? JSONEncoder().encode(self)
    }
    
    var formURLEncodedData: Data? {
        let queryItems = encodedQueryItems
        var components = URLComponents()
        components.queryItems = queryItems
        return components.query?.data(using: .utf8)
    }
    
    private func encodeQueryValue(key: String, value: Any) -> [URLQueryItem] {
        if let array = value as? [Any] {
            return array.enumerated().flatMap { index, element -> [URLQueryItem] in
                encodeQueryValue(key: "\(key)[\(index)]", value: element)
            }
        } else if let dict = value as? [String: Any] {
            return dict.flatMap { nestedKey, nestedValue -> [URLQueryItem] in
                encodeQueryValue(key: "\(key)[\(nestedKey)]", value: nestedValue)
            }
        } else {
            let stringValue = stringRepresentation(of: value)
            return [URLQueryItem(name: key, value: stringValue)]
        }
    }
    
    private func stringRepresentation(of value: Any) -> String {
        switch value {
        case let string as String:
            return string
        case let number as NSNumber:
            if CFBooleanGetTypeID() == CFGetTypeID(number) {
                return number.boolValue ? "true" : "false"
            }
            return number.stringValue
        case let bool as Bool:
            return bool ? "true" : "false"
        default:
            return "\(value)"
        }
    }
}
