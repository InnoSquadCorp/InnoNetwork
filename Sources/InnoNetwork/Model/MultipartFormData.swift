import Foundation
import UniformTypeIdentifiers


public struct MultipartFormData: Sendable {
    public let boundary: String
    private var parts: [Part]
    
    public init(boundary: String = UUID().uuidString) {
        self.boundary = boundary
        self.parts = []
    }
    
    public mutating func append(_ data: Data, name: String, fileName: String? = nil, mimeType: String? = nil) {
        parts.append(Part(data: data, name: name, fileName: fileName, mimeType: mimeType))
    }
    
    public mutating func append(_ string: String, name: String) {
        if let data = string.data(using: .utf8) {
            parts.append(Part(data: data, name: name, fileName: nil, mimeType: nil))
        }
    }
    
    public mutating func append(_ value: Int, name: String) {
        append(String(value), name: name)
    }
    
    public mutating func append(_ value: Double, name: String) {
        append(String(value), name: name)
    }
    
    public mutating func append(_ value: Bool, name: String) {
        append(value ? "true" : "false", name: name)
    }
    
    public mutating func appendFile(at url: URL, name: String, mimeType: String? = nil) throws {
        let data = try Data(contentsOf: url)
        let fileName = url.lastPathComponent
        let detectedMimeType = mimeType ?? Self.mimeType(for: url.pathExtension)
        parts.append(Part(data: data, name: name, fileName: fileName, mimeType: detectedMimeType))
    }
    
    public func encode() -> Data {
        var body = Data()
        let boundaryPrefix = "--\(boundary)\r\n"
        
        for part in parts {
            body.append(Data(boundaryPrefix.utf8))
            
            var disposition = "Content-Disposition: form-data; name=\"\(part.name)\""
            if let fileName = part.fileName {
                disposition += "; filename=\"\(fileName)\""
            }
            disposition += "\r\n"
            body.append(Data(disposition.utf8))
            
            if let mimeType = part.mimeType {
                body.append(Data("Content-Type: \(mimeType)\r\n".utf8))
            }
            
            body.append(Data("\r\n".utf8))
            body.append(part.data)
            body.append(Data("\r\n".utf8))
        }
        
        body.append(Data("--\(boundary)--\r\n".utf8))
        return body
    }
    
    public var contentTypeHeader: String {
        "multipart/form-data; boundary=\(boundary)"
    }
    
    static func mimeType(for pathExtension: String) -> String {
        // UTType is available on every platform InnoNetwork ships against
        // (iOS 18+, macOS 15+, tvOS 18+, watchOS 11+, visionOS 2+), so it
        // can replace the hand-curated extension table without an
        // availability shim. The fallback matches the previous default of
        // application/octet-stream for unknown extensions.
        UTType(filenameExtension: pathExtension)?.preferredMIMEType ?? "application/octet-stream"
    }
}


extension MultipartFormData {
    struct Part: Sendable {
        let data: Data
        let name: String
        let fileName: String?
        let mimeType: String?
    }
}
