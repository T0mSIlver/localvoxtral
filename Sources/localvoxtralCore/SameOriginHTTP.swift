import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The URLSession for every request that carries dictated text, context or a
/// key. It follows a redirect only within the origin (scheme, host, port) the
/// request was sent to. A 307 or 308 resends the body, so following one off
/// that origin would carry context past the destination gate, which approves
/// the configured URL only. A refused redirect completes the request with the
/// 3xx response itself.
///
/// A session-wide delegate rather than a per-task one: Linux's Foundation
/// asks only the session's delegate about redirects.
package enum SameOriginHTTP {
    /// One for the app: a URLSession lives until invalidated.
    package static let shared = session(configuration: .default)

    package static func session(configuration: URLSessionConfiguration) -> URLSession {
        URLSession(configuration: configuration, delegate: RedirectGate(), delegateQueue: nil)
    }

    package static func isSameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        guard let lhsScheme = lhs.scheme?.lowercased(), let rhsScheme = rhs.scheme?.lowercased(),
              let lhsHost = lhs.host?.lowercased(), let rhsHost = rhs.host?.lowercased()
        else { return false }
        return lhsScheme == rhsScheme && lhsHost == rhsHost
            && effectivePort(lhs, scheme: lhsScheme) == effectivePort(rhs, scheme: rhsScheme)
    }

    private static func effectivePort(_ url: URL, scheme: String) -> Int? {
        url.port ?? (scheme == "https" ? 443 : scheme == "http" ? 80 : nil)
    }

    private final class RedirectGate: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping @Sendable (URLRequest?) -> Void
        ) {
            guard let from = task.originalRequest?.url, let to = request.url,
                  SameOriginHTTP.isSameOrigin(from, to)
            else {
                Log.backends.error(
                    "HTTP redirect to another origin refused (HTTP \(response.statusCode, privacy: .public))"
                )
                completionHandler(nil)
                return
            }
            completionHandler(request)
        }
    }
}
