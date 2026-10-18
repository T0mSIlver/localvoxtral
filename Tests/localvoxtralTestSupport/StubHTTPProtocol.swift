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
        /// A 200 whose body starts and never finishes: a server that keeps
        /// the connection alive without answering.
        case stalls
    }

    package static let host = "usage-stub.invalid"
    package static let reply = Mutex<Reply>(.http(500, ""))
    /// Every request the stub answered, oldest first, with its body read
    /// back from the stream URLSession turns it into.
    package static let recorded = Mutex<[URLRequest]>([])

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
        var copy = request
        copy.httpBody = Self.body(of: request)
        Self.recorded.withLock { $0.append(copy) }
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
        case .stalls:
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("{".utf8))
        }
    }

    override package func stopLoading() {}

    private static func body(of request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

extension StubHTTPProtocol {
    final class AnyHost: StubHTTPProtocol, @unchecked Sendable {
        override class func canInit(with request: URLRequest) -> Bool { true }
    }
}
