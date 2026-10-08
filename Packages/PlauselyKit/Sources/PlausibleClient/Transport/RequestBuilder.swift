import Foundation

/// Structured request builder. Enforces the transport contract:
/// HTTPS by default (HTTP only for loopback during local evaluation),
/// no userinfo/fragments/unsupported schemes, preserved reverse-proxy
/// prefix, structural path/query/JSON encoding. Diagnostics never include
/// secrets: `sanitizedDescription` redacts Cookie/Authorization values.
public struct RequestBuilder: Sendable {
    public let baseURL: URL
    public let allowsInsecureLoopback: Bool

    public enum BuildError: Error, Equatable {
        case unsupportedScheme(String?)
        case userinfoPresent
        case fragmentPresent
        case insecureNonLoopback(String)
    }

    public init(baseURL: URL, allowsInsecureLoopback: Bool = true) throws {
        let scheme = baseURL.scheme?.lowercased()
        guard scheme == "https" || scheme == "http" else {
            throw BuildError.unsupportedScheme(baseURL.scheme)
        }
        guard baseURL.user == nil, baseURL.password == nil else {
            throw BuildError.userinfoPresent
        }
        guard baseURL.fragment == nil else {
            throw BuildError.fragmentPresent
        }
        if scheme == "http" {
            let host = baseURL.host?.lowercased() ?? ""
            let loopback = host == "localhost" || host == "127.0.0.1" || host == "::1"
            guard allowsInsecureLoopback, loopback else {
                throw BuildError.insecureNonLoopback(host)
            }
        }
        self.baseURL = baseURL
        self.allowsInsecureLoopback = allowsInsecureLoopback
    }

    /// Builds a GET for a stats path with structured query items.
    /// `path` carries pre-encoded segments (see `ReportKind.path()`); it is
    /// concatenated onto any preserved reverse-proxy prefix WITHOUT
    /// re-encoding, so `%2F` drilldown segments survive exactly once.
    /// `accept` defaults to JSON; HTML-pipeline routes (dashboard export)
    /// need `text/html` or the server answers 406.
    public func get(path: String, query: [URLQueryItem] = [], headers: [String: String] = [:], accept: String = "application/json") -> URLRequest {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        let prefix = components.percentEncodedPath
        components.percentEncodedPath = (prefix == "/" || prefix.isEmpty ? "" : prefix) + "/" + path
        components.queryItems = query.isEmpty ? nil : query
        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.setValue(accept, forHTTPHeaderField: "Accept")
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        return request
    }

    /// Builds a JSON mutation request. Mutations never retry on ambiguity;
    /// callers must use a non-idempotent transport.
    public func mutation(path: String, method: String, body: [String: Any], headers: [String: String] = [:]) throws -> URLRequest {
        var request = get(path: path, headers: headers)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.withoutEscapingSlashes])
        return request
    }

    /// Log-safe description: URL plus redacted header names only.
    public static func sanitizedDescription(for request: URLRequest) -> String {
        var parts = ["\(request.httpMethod ?? "?") \(request.url?.absoluteString ?? "?")"]
        for field in (request.allHTTPHeaderFields ?? [:]).keys.sorted() {
            let sensitive = field.lowercased() == "cookie" || field.lowercased() == "authorization"
            parts.append("\(field): \(sensitive ? "<redacted>" : (request.value(forHTTPHeaderField: field) ?? ""))")
        }
        return parts.joined(separator: " | ")
    }
}
