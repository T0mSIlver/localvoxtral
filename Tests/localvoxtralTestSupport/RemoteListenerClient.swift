import Foundation
import Synchronization
import XCTest
import localvoxtralCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// A host registry file kept in memory.
package final class MemoryRemoteHostStoreIO: ClaudeRemoteHostStoreIO, @unchecked Sendable {
    private let contents = Mutex<Data?>(nil)
    package init() {}
    package func read(from url: URL) throws -> Data? { contents.withLock { $0 } }
    package func write(_ data: Data, to url: URL) throws { contents.withLock { $0 = data } }
}

/// One answer from the remote listener, as a host's curl sees it.
package struct RemoteListenerResponse: Sendable {
    package var status: Int
    /// Lowercased names.
    package var headers: [String: String]
    package var body: Data
}

/// One POST to the remote listener on `127.0.0.1:port`, over a real socket,
/// the way the host shims send it: one request per connection.
package func postToRemoteListener(
    port: UInt16,
    path: String,
    headers: [String: String],
    body: Data,
    contentLength: Int? = nil
) throws -> RemoteListenerResponse {
    var head = "POST \(path) HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: \(contentLength ?? body.count)\r\n"
    for (name, value) in headers.sorted(by: { $0.key < $1.key }) { head += "\(name): \(value)\r\n" }
    head += "\r\n"
    let request = Data(head.utf8) + body

    let fd = socket(AF_INET, POSIXSocket.stream, 0)
    guard fd >= 0 else { throw POSIXError(.EBADF) }
    defer { close(fd) }
    var address = sockaddr_in()
    POSIXSocket.setLength(of: &address)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    address.sin_addr = in_addr(s_addr: INADDR_LOOPBACK.bigEndian)
    let connected = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard connected == 0 else { throw POSIXError(.ECONNREFUSED) }
    var timeout = timeval(tv_sec: 5, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    _ = request.withUnsafeBytes { raw -> Int in
        var offset = 0
        while offset < raw.count {
            let written = write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
            if written <= 0 { break }
            offset += written
        }
        return offset
    }
    shutdown(fd, Int32(SHUT_WR))
    var received = Data()
    var chunk = [UInt8](repeating: 0, count: 4096)
    while true {
        let count = read(fd, &chunk, chunk.count)
        if count <= 0 { break }
        received.append(contentsOf: chunk[0..<count])
    }
    guard let split = received.range(of: Data("\r\n\r\n".utf8)) else {
        return RemoteListenerResponse(status: 0, headers: [:], body: Data())
    }
    let lines = String(decoding: received[..<split.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
    let status = Int(lines.first?.split(separator: " ").dropFirst().first ?? "") ?? 0
    var parsed: [String: String] = [:]
    for line in lines.dropFirst() {
        guard let colon = line.firstIndex(of: ":") else { continue }
        parsed[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
    }
    return RemoteListenerResponse(status: status, headers: parsed, body: Data(received[split.upperBound...]))
}

/// A sleep seam whose sleepers wake only when a test says so.
package final class ManualSleeper: @unchecked Sendable {
    private struct State {
        var sleepers: [CheckedContinuation<Void, Never>] = []
        var watchers: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    }

    private let state = Mutex(State())

    package init() {}

    package func sleep(_ seconds: TimeInterval) async {
        await withCheckedContinuation { continuation in
            let ready = state.withLock { state -> [CheckedContinuation<Void, Never>] in
                state.sleepers.append(continuation)
                let count = state.sleepers.count
                let ready = state.watchers.filter { $0.count <= count }.map(\.continuation)
                state.watchers.removeAll { $0.count <= count }
                return ready
            }
            ready.forEach { $0.resume() }
        }
    }

    /// Returns once `count` sleepers are waiting.
    package func waitForSleepers(_ count: Int) async {
        await withCheckedContinuation { continuation in
            let now = state.withLock { state -> Bool in
                if state.sleepers.count >= count { return true }
                state.watchers.append((count, continuation))
                return false
            }
            if now { continuation.resume() }
        }
    }

    /// Wakes every sleeper.
    package func wakeAll() {
        let woken = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            defer { state.sleepers = [] }
            return state.sleepers
        }
        woken.forEach { $0.resume() }
    }
}
