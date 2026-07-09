import Foundation

public struct HTTPRequest: Sendable, Equatable {
    public var method: String
    public var path: String
    public var body: Data

    public init(method: String, path: String, body: Data = Data()) {
        self.method = method
        self.path = path
        self.body = body
    }
}

public struct HTTPResponse: Sendable {
    public var status: Int
    public var body: Data
    public var contentType: String

    public init(status: Int, body: Data, contentType: String = "application/json") {
        self.status = status
        self.body = body
        self.contentType = contentType
    }

    public static func json(_ status: Int, _ value: some Encodable) -> HTTPResponse {
        let body = (try? JSONEncoder().encode(value)) ?? Data("{}".utf8)
        return HTTPResponse(status: status, body: body)
    }

    var reasonPhrase: String {
        switch status {
        case 200: "OK"
        case 400: "Bad Request"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 500: "Internal Server Error"
        default: "Response"
        }
    }

    public func serialized() -> Data {
        var head = "HTTP/1.1 \(status) \(reasonPhrase)\r\n"
        head += "Content-Type: \(contentType)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Connection: close\r\n\r\n"
        return Data(head.utf8) + body
    }
}

public enum HTTPParseError: Error, Equatable {
    case malformedRequestLine
    case invalidContentLength
    case bodyTooLarge(limit: Int)
    case headTooLarge(limit: Int)
}

/// Incremental HTTP/1.1 request parser: feed it chunks as they arrive on the
/// socket, get a complete request back once the head and declared body are in.
/// Pure value type so it is trivially unit-testable without sockets.
public struct HTTPRequestAccumulator: Sendable {
    public static let maxBodyBytes = 8 << 20
    public static let maxHeadBytes = 64 << 10

    private var buffer = Data()
    private var head: (method: String, path: String, contentLength: Int)?

    public init() {}

    public mutating func append(_ chunk: Data) throws -> HTTPRequest? {
        buffer.append(chunk)

        if head == nil {
            guard let headEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                // Bound what a peer can make us buffer while it withholds the
                // blank line — real clients send a complete head in one or two
                // segments.
                guard buffer.count <= Self.maxHeadBytes else {
                    throw HTTPParseError.headTooLarge(limit: Self.maxHeadBytes)
                }
                return nil
            }
            let headData = buffer.subdata(in: buffer.startIndex ..< headEnd.lowerBound)
            guard let headText = String(data: headData, encoding: .utf8) else {
                throw HTTPParseError.malformedRequestLine
            }
            let lines = headText.components(separatedBy: "\r\n")
            let requestLine = lines[0].split(separator: " ")
            guard requestLine.count == 3 else {
                throw HTTPParseError.malformedRequestLine
            }
            var contentLength = 0
            for line in lines.dropFirst() {
                let parts = line.split(separator: ":", maxSplits: 1)
                guard parts.count == 2 else { continue }
                if parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length" {
                    guard let parsed = Int(parts[1].trimmingCharacters(in: .whitespaces)),
                        parsed >= 0
                    else {
                        // A negative value would trap in prefix(_:) below;
                        // reject the request instead of crashing the helper.
                        throw HTTPParseError.invalidContentLength
                    }
                    contentLength = parsed
                }
            }
            guard contentLength <= Self.maxBodyBytes else {
                throw HTTPParseError.bodyTooLarge(limit: Self.maxBodyBytes)
            }
            head = (String(requestLine[0]), String(requestLine[1]), contentLength)
            buffer.removeSubrange(buffer.startIndex ..< headEnd.upperBound)
        }

        guard let head, buffer.count >= head.contentLength else {
            return nil
        }
        let body = buffer.prefix(head.contentLength)
        return HTTPRequest(method: head.method, path: head.path, body: Data(body))
    }
}
