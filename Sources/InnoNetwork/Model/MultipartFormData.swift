import Foundation


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
    
    private static func mimeType(for pathExtension: String) -> String {
        switch pathExtension.lowercased() {
        case "jpg", "jpeg":
            return "image/jpeg"
        case "png":
            return "image/png"
        case "gif":
            return "image/gif"
        case "heic":
            return "image/heic"
        case "pdf":
            return "application/pdf"
        case "json":
            return "application/json"
        case "txt":
            return "text/plain"
        case "html":
            return "text/html"
        case "mp4":
            return "video/mp4"
        case "mov":
            return "video/quicktime"
        case "mp3":
            return "audio/mpeg"
        case "wav":
            return "audio/wav"
        case "zip":
            return "application/zip"
        default:
            return "application/octet-stream"
        }
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
