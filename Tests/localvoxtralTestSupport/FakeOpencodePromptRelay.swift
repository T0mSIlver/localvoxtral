import ClaudeContextWire
import Foundation
import localvoxtralCore
import Synchronization
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// The opencode plugin's prompt relay as the app sees it (#719): an HTTP
/// listener on 127.0.0.1, port 0, that records every call and answers each
/// with the status `status` picks (200 by default). One connection at a
/// time, as the app's client makes them.
package final class FakeOpencodePromptRelay: @unchecked Sendable {
    package struct Call: Sendable, Equatable {
        package var method: String
        package var path: String
        package var authorization: String?
        package var sessionID: String?
        package var text: String?
    }

    package let port: Int
    package let token = String(repeating: "5a", count: 32)

    private let listener: Int32
    private let status: @Sendable (Call) -> Int
    private let state = Mutex<(calls: [Call], watches: [(count: Int, wait: BoundedWait)], stopped: Bool)>(
        ([], [], false)
    )

    package init(status: @escaping @Sendable (Call) -> Int = { _ in 200 }) throws {
        self.status = status
        let descriptor = socket(AF_INET, POSIXSocket.stream, 0)
        guard descriptor >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        var address = sockaddr_in()
        POSIXSocket.setLength(of: &address)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: INADDR_LOOPBACK.bigEndian)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        var assigned = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &assigned) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length)
            }
        }
        guard bound == 0, named == 0, listen(descriptor, 8) == 0 else {
            close(descriptor)
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        listener = descriptor
        port = Int(UInt16(bigEndian: assigned.sin_port))
        Thread { [self] in serve() }.start()
    }

    /// The relay a focus declaration would have published for this fixture.
    package func relay(sessionID: String) -> OpencodePromptRelay {
        OpencodePromptRelay(
            address: OpencodePromptRelayAddress(port: port, token: token),
            opencodeSessionID: sessionID
        )
    }

    package var calls: [Call] { state.withLock { $0.calls } }

    /// True once `count` calls arrived; false if they did not within
    /// `failAfter` seconds of wall time.
    package func waitForCalls(
        _ count: Int, failAfter: TimeInterval = 10,
        isolation: isolated (any Actor)? = #isolation
    ) async -> Bool {
        let wait = BoundedWait()
        let reached = state.withLock { state -> Bool in
            if state.calls.count >= count { return true }
            state.watches.append((count, wait))
            return false
        }
        if reached { return true }
        return await wait.value(failAfter: failAfter)
    }

    package func stop() {
        let wasStopped = state.withLock { state -> Bool in
            defer { state.stopped = true }
            return state.stopped
        }
        guard !wasStopped else { return }
        // A blocked accept() does not return on shutdown() on macOS: dial it.
        wakeAccept()
        close(listener)
    }

    private func serve() {
        while true {
            let connection = accept(listener, nil, nil)
            if state.withLock({ $0.stopped }) {
                if connection >= 0 { close(connection) }
                return
            }
            guard connection >= 0 else { return }
            handle(connection)
            close(connection)
        }
    }

    private func handle(_ connection: Int32) {
        var buffer = [UInt8]()
        var chunk = [UInt8](repeating: 0, count: 4096)
        var headerEnd: Int?
        var contentLength = 0
        while true {
            if let end = headerEnd, buffer.count >= end + contentLength { break }
            let count = recv(connection, &chunk, chunk.count, 0)
            guard count > 0 else { return }
            buffer.append(contentsOf: chunk[0..<count])
            if headerEnd == nil, let range = Self.find([13, 10, 13, 10], in: buffer) {
                headerEnd = range + 4
                let head = String(decoding: buffer[0..<range], as: UTF8.self)
                for line in head.split(separator: "\r\n") {
                    let parts = line.split(separator: ":", maxSplits: 1)
                    if parts.count == 2, parts[0].lowercased() == "content-length" {
                        contentLength = Int(parts[1].trimmingCharacters(in: .whitespaces)) ?? 0
                    }
                }
            }
        }
        guard let end = headerEnd else { return }
        let head = String(decoding: buffer[0..<(end - 4)], as: UTF8.self)
        let lines = head.split(separator: "\r\n")
        let requestLine = lines.first.map { $0.split(separator: " ") } ?? []
        var authorization: String?
        for line in lines.dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2, parts[0].lowercased() == "authorization" {
                authorization = parts[1].trimmingCharacters(in: .whitespaces)
            }
        }
        let body = Data(buffer[end..<(end + contentLength)])
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let call = Call(
            method: requestLine.count > 0 ? String(requestLine[0]) : "",
            path: requestLine.count > 1 ? String(requestLine[1]) : "",
            authorization: authorization,
            sessionID: json?["session_id"] as? String,
            text: json?["text"] as? String
        )
        let code = status(call)
        let reply = "HTTP/1.1 \(code) Fake\r\nContent-Type: application/json\r\nContent-Length: 4\r\nConnection: close\r\n\r\ntrue"
        _ = reply.utf8CString.withUnsafeBufferPointer { pointer in
            send(connection, pointer.baseAddress, pointer.count - 1, POSIXSocket.sendFlags)
        }
        let ready = state.withLock { state -> [BoundedWait] in
            state.calls.append(call)
            let reached = state.watches.filter { $0.count <= state.calls.count }.map(\.wait)
            state.watches.removeAll { $0.count <= state.calls.count }
            return reached
        }
        for wait in ready { wait.resolve() }
    }

    private func wakeAccept() {
        let descriptor = socket(AF_INET, POSIXSocket.stream, 0)
        guard descriptor >= 0 else { return }
        defer { close(descriptor) }
        var address = sockaddr_in()
        POSIXSocket.setLength(of: &address)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        address.sin_addr = in_addr(s_addr: INADDR_LOOPBACK.bigEndian)
        _ = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                LibC.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
    }

    private static func find(_ needle: [UInt8], in haystack: [UInt8]) -> Int? {
        guard haystack.count >= needle.count else { return nil }
        for start in 0...(haystack.count - needle.count) where Array(haystack[start..<(start + needle.count)]) == needle {
            return start
        }
        return nil
    }
}
