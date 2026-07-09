import XCTest

@testable import PolishHelperCore

final class HTTPMessageTests: XCTestCase {
    func testParsesRequestDeliveredInOneChunk() throws {
        var accumulator = HTTPRequestAccumulator()
        let raw = "POST /v1/chat/completions HTTP/1.1\r\nHost: x\r\nContent-Length: 4\r\n\r\nbody"
        let request = try accumulator.append(Data(raw.utf8))
        XCTAssertEqual(request, HTTPRequest(method: "POST", path: "/v1/chat/completions", body: Data("body".utf8)))
    }

    func testParsesRequestDeliveredBytewise() throws {
        var accumulator = HTTPRequestAccumulator()
        let raw = "POST /x HTTP/1.1\r\ncontent-length: 5\r\n\r\nhello"
        var request: HTTPRequest?
        for byte in Data(raw.utf8) {
            XCTAssertNil(request)
            request = try accumulator.append(Data([byte]))
        }
        XCTAssertEqual(request, HTTPRequest(method: "POST", path: "/x", body: Data("hello".utf8)))
    }

    func testParsesGetWithoutBody() throws {
        var accumulator = HTTPRequestAccumulator()
        let request = try accumulator.append(Data("GET /health HTTP/1.1\r\nHost: x\r\n\r\n".utf8))
        XCTAssertEqual(request, HTTPRequest(method: "GET", path: "/health"))
    }

    func testHeaderNamesAreCaseInsensitiveAndBodyWaitsForAllBytes() throws {
        var accumulator = HTTPRequestAccumulator()
        XCTAssertNil(try accumulator.append(Data("POST /x HTTP/1.1\r\nCONTENT-LENGTH: 6\r\n\r\nabc".utf8)))
        let request = try accumulator.append(Data("def".utf8))
        XCTAssertEqual(request?.body, Data("abcdef".utf8))
    }

    func testMalformedRequestLineThrows() {
        var accumulator = HTTPRequestAccumulator()
        XCTAssertThrowsError(try accumulator.append(Data("NONSENSE\r\n\r\n".utf8))) { error in
            XCTAssertEqual(error as? HTTPParseError, .malformedRequestLine)
        }
    }

    func testOversizedBodyIsRejectedUpFront() {
        var accumulator = HTTPRequestAccumulator()
        let raw = "POST /x HTTP/1.1\r\nContent-Length: \(HTTPRequestAccumulator.maxBodyBytes + 1)\r\n\r\n"
        XCTAssertThrowsError(try accumulator.append(Data(raw.utf8))) { error in
            XCTAssertEqual(error as? HTTPParseError, .bodyTooLarge(limit: HTTPRequestAccumulator.maxBodyBytes))
        }
    }

    func testNegativeContentLengthIsRejectedNotTrapped() {
        // Regression: Int("-1") parses, and buffer.prefix(-1) traps — a local
        // peer could crash the helper with one malformed request.
        var accumulator = HTTPRequestAccumulator()
        let raw = "POST /x HTTP/1.1\r\nContent-Length: -1\r\n\r\n"
        XCTAssertThrowsError(try accumulator.append(Data(raw.utf8))) { error in
            XCTAssertEqual(error as? HTTPParseError, .invalidContentLength)
        }
    }

    func testNonNumericContentLengthIsRejected() {
        var accumulator = HTTPRequestAccumulator()
        let raw = "POST /x HTTP/1.1\r\nContent-Length: abc\r\n\r\n"
        XCTAssertThrowsError(try accumulator.append(Data(raw.utf8))) { error in
            XCTAssertEqual(error as? HTTPParseError, .invalidContentLength)
        }
    }

    func testEndlessHeadWithoutBlankLineIsBounded() {
        // A peer streaming header bytes forever must not grow memory
        // unboundedly while we wait for \r\n\r\n.
        var accumulator = HTTPRequestAccumulator()
        let filler = Data(repeating: UInt8(ascii: "a"), count: HTTPRequestAccumulator.maxHeadBytes + 1)
        XCTAssertThrowsError(try accumulator.append(filler)) { error in
            XCTAssertEqual(error as? HTTPParseError, .headTooLarge(limit: HTTPRequestAccumulator.maxHeadBytes))
        }
    }

    func testResponseSerializationIncludesLengthAndClose() {
        let response = HTTPResponse(status: 200, body: Data("{\"a\":1}".utf8))
        let text = String(decoding: response.serialized(), as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("HTTP/1.1 200 OK\r\n"))
        XCTAssertTrue(text.contains("Content-Length: 7\r\n"))
        XCTAssertTrue(text.contains("Connection: close\r\n"))
        XCTAssertTrue(text.hasSuffix("\r\n\r\n{\"a\":1}"))
    }
}
