import Foundation


package struct RequestBuilder {
    package init() {}

    package func build<D: SingleRequestExecutable>(
        _ executable: D,
        configuration: NetworkConfiguration
    ) throws -> URLRequest {
        let payload = try executable.makePayload()
        var targetURL = configuration.baseURL.appendingPathComponent(executable.path)
        var httpBody: Data?

        switch payload {
        case .none:
            break
        case .data(let data):
            httpBody = data
        case .queryItems(let queryItems):
            targetURL.append(queryItems: queryItems)
        }

        var request = URLRequest(url: targetURL)
        request.httpMethod = executable.method.rawValue
        request.allHTTPHeaderFields = executable.headers.dictionary
        request.cachePolicy = configuration.cachePolicy
        request.timeoutInterval = configuration.timeout
        request.httpBody = httpBody
        return request
    }
}

