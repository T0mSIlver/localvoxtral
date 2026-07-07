import XCTest

@testable import PolishHelperCore

final class HTTPServerTests: XCTestCase {
    func testServesRequestsOverLoopback() async throws {
        let server = try HTTPServer(port: 0) { request in
            if request.method == "GET" && request.path == "/health" {
                return .json(200, ["status": "ok"])
            }
            return HTTPResponse(status: 200, body: request.body)
        }
        try await server.start()
        defer { server.stop() }
        let port = server.boundPort
        XCTAssertNotEqual(port, 0)

        // GET round-trip.
        let healthURL = URL(string: "http://127.0.0.1:\(port)/health")!
        let (healthBody, healthResponse) = try await URLSession.shared.data(from: healthURL)
        XCTAssertEqual((healthResponse as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(
            try JSONDecoder().decode([String: String].self, from: healthBody),
            ["status": "ok"]
        )

        // POST round-trip: the body comes back verbatim (echo handler).
        var post = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/echo")!)
        post.httpMethod = "POST"
        post.httpBody = Data("payload-bytes".utf8)
        let (echoBody, echoResponse) = try await URLSession.shared.data(for: post)
        XCTAssertEqual((echoResponse as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(echoBody, Data("payload-bytes".utf8))
    }

    func testConcurrentRequestsAllComplete() async throws {
        let server = try HTTPServer(port: 0) { request in
            HTTPResponse(status: 200, body: request.body)
        }
        try await server.start()
        defer { server.stop() }
        let port = server.boundPort

        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<8 {
                group.addTask {
                    var post = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/echo")!)
                    post.httpMethod = "POST"
                    post.httpBody = Data("request-\(index)".utf8)
                    let (body, _) = try await URLSession.shared.data(for: post)
                    XCTAssertEqual(body, Data("request-\(index)".utf8))
                }
            }
            try await group.waitForAll()
        }
    }
}
