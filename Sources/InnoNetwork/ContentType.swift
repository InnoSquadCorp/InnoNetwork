//
//  ContentType.swift
//  Network
//
//  Created by Chang Woo Son on 6/20/24.
//

import Foundation


public enum ContentType: String {
    case json = "application/json"
    case xml = "application/xml"
    case formUrlEncoded = "application/x-www-form-urlencoded"
    case textHTML = "text/html"
    case textPlain = "text/plain"
    case multipartFormData = "multipart/form-data"
    case imagePNG = "image/png"
    case imageJPEG = "image/jpeg"
    case pdf = "application/pdf"
    case protobuf = "application/x-protobuf"
}
