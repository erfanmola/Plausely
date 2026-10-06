import Foundation

/// Injected transport seam. Production uses `URLSessionTransport`;
/// tests inject fakes. Cancellation flows through Swift concurrency.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest, expecting: ContentKind) async throws -> (Data, HTTPURLResponse)
}

extension HTTPTransport {
    /// JSON-contract shorthand.
    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await send(request, expecting: .json)
    }
}

/// Retry policy. Only idempotent reads retry, finitely, honoring Retry-After.
public struct RetryPolicy: Sendable {
    public let maxRetries: Int
    public let retryAfterCap: Int
    public init(maxRetries: Int = 2, retryAfterCap: Int = 60) {
        self.maxRetries = maxRetries
        self.retryAfterCap = retryAfterCap
    }

    public func delay(for error: ClientError, attempt: Int) -> Int? {
        guard error.retryable, attempt < maxRetries else { return nil }
        switch error {
        case .rateLimited(let retryAfter):
            return min(retryAfter ?? 1, retryAfterCap)
        default:
            return min(1 << attempt, retryAfterCap)
        }
    }
}

/// URLSession transport with a same-origin redirect policy: relative and
/// same-origin redirects are followed; anything that would change the origin
/// cancels the navigation so cookies/credentials never leak cross-origin.
public final class URLSessionTransport: NSObject, HTTPTransport, Sendable {
    private let session: URLSession
    private let policy: RetryPolicy
    private let idempotent: Bool

    public init(configuration: URLSessionConfiguration = .ephemeral, policy: RetryPolicy = RetryPolicy(), idempotent: Bool = true) {
        self.policy = policy
        self.idempotent = idempotent
        let delegate = RedirectGuard()
        self.session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        super.init()
        // Retain guard via session's strong delegate reference.
    }

    public func send(_ request: URLRequest, expecting: ContentKind = .json) async throws -> (Data, HTTPURLResponse) {
        var attempt = 0
        while true {
            do {
                try Task.checkCancellation()
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw ClientError.serverError(status: -1)
                }
                if let mapped = ErrorMapper.map(data: data, response: http, expecting: expecting) {
                    throw mapped
                }
                return (data, http)
            } catch let error as ClientError {
                if idempotent, let delay = policy.delay(for: error, attempt: attempt) {
                    attempt += 1
                    try await Task.sleep(for: .seconds(delay))
                    continue
                }
                throw error
            } catch is CancellationError {
                throw ClientError.cancelled
            } catch let urlError as URLError {
                if urlError.code == .cancelled || urlError.code == .userCancelledAuthentication {
                    throw ClientError.cancelled
                }
                let mapped = ClientError.transport(code: urlError.code.rawValue)
                if idempotent, let delay = policy.delay(for: mapped, attempt: attempt) {
                    attempt += 1
                    try await Task.sleep(for: .seconds(delay))
                    continue
                }
                throw mapped
            }
        }
    }
}

/// Same-origin redirect guard. Pure decision function is unit-tested;
/// the delegate applies it to live navigations.
public enum RedirectPolicy {
    public static func allowsRedirect(from request: URLRequest, to url: URL) -> Bool {
        guard let fromHost = request.url?.host?.lowercased(),
              let toHost = url.host?.lowercased(),
              let fromScheme = request.url?.scheme?.lowercased(),
              let toScheme = url.scheme?.lowercased()
        else { return false }
        return fromHost == toHost && fromScheme == toScheme
    }
}

private final class RedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let url = request.url,
              let original = task.originalRequest,
              RedirectPolicy.allowsRedirect(from: original, to: url) else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}
