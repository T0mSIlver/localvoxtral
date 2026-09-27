import Foundation
import Synchronization
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Answers every request to its reserved host with `reply`, so an HTTP path
/// runs with no network. Register it globally for code on
/// `URLSession.shared`, or hand `session()` to code that takes a session:
/// that one answers every host, for code whose endpoint is fixed.
package class StubHTTPProtocol: URLProtocol, @unchecked Sendable {
    package enum Reply: Sendable {
        case http(Int, String)
        case failure(URLError)
    }

    package static let host = "usage-stub.invalid"
    package static let reply = Mutex<Reply>(.http(500, ""))

    /// A session whose every request this stub answers.
    package static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AnyHost.self]
        return URLSession(configuration: configuration)
    }

    override package class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == host
    }

    override package class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override package func startLoading() {
        switch Self.reply.withLock({ $0 }) {
        case .http(let status, let body):
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        case .failure(let error):
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override package func stopLoading() {}
}

extension StubHTTPProtocol {
    final class AnyHost: StubHTTPProtocol, @unchecked Sendable {
        override class func canInit(with request: URLRequest) -> Bool { true }
    }
}
