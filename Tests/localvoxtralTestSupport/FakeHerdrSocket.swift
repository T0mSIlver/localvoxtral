import Foundation
import localvoxtralCore
import Synchronization
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// herdr's control socket as the app sees it (#726): an AF_UNIX listener that
/// takes one JSON request per connection, as herdr does, records it, and
/// answers with what `answer` picks. Every request is kept, so a test can
/// assert the exact calls made and that no other method was ever sent.
package final class FakeHerdrSocket: @unchecked Sendable {
    package struct Request: Sendable, Equatable {
        package var method: String
        package var paneID: String?
        package var text: String?
        package var keys: [String]?

        package init(method: String, paneID: String?, text: String?, keys: [String]?) {
            self.method = method
            self.paneID = paneID
            self.text = text
            self.keys = keys
        }
    }

    package enum Answer: Sendable {
        case ok
        /// herdr's error envelope with this code (`pane_not_found`, ...).
        case error(String)
        /// Close the connection without a reply.
        case hangUp
        /// A raw reply line, for answers no well-behaved herdr sends.
        case raw(String)
    }

    package let socketPath: String
    private let directory: URL
    private let listener: Int32
    private let answer: @Sendable (Request) -> Answer
    private typealias Watch = (reached: @Sendable ([Request]) -> Bool, wait: BoundedWait)
    private let state = Mutex<(requests: [Request], watches: [Watch], stopped: Bool)>(([], [], false))

    package init(answer: @escaping @Sendable (Request) -> Answer = { _ in .ok }) throws {
        self.answer = answer
        // Short and unique: `sun_path` is 104 bytes on macOS, and test
        // classes run in several processes at once.
        directory = URL(fileURLWithPath: "/tmp/lvx-fh-\(UUID().uuidString.prefix(8))")
        socketPath = directory.appendingPathComponent("s").path
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
        )
        let descriptor = socket(AF_UNIX, POSIXSocket.stream, 0)
        guard descriptor >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        POSIXSocket.setLength(of: &address)
        let bytes = Array(socketPath.utf8)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(descriptor, 8) == 0 else {
            let code = POSIXErrorCode(rawValue: errno) ?? .EIO
            close(descriptor)
            try? FileManager.default.removeItem(at: directory)
            throw POSIXError(code)
        }
        _ = chmod(socketPath, 0o600)
        listener = descriptor
        Thread { [self] in serve() }.start()
    }

    package var requests: [Request] { state.withLock { $0.requests } }

    /// The text every `pane.send_text` carried, joined in arrival order.
    package var sentText: String {
        requests.filter { $0.method == "pane.send_text" }.compactMap(\.text).joined()
    }

    /// True once `count` requests arrived; false if they did not within
    /// `failAfter` seconds of wall time.
    package func waitForRequests(
        _ count: Int, failAfter: TimeInterval = 10,
        isolation: isolated (any Actor)? = #isolation
    ) async -> Bool {
        await waitUntil(failAfter: failAfter) { $0.count >= count }
    }

    package func waitUntil(
        failAfter: TimeInterval = 10,
        isolation: isolated (any Actor)? = #isolation,
        _ reached: @escaping @Sendable ([Request]) -> Bool
    ) async -> Bool {
        let wait = BoundedWait()
        let already = state.withLock { state -> Bool in
            if reached(state.requests) { return true }
            state.watches.append((reached, wait))
            return false
        }
        if already { return true }
        return await wait.value(failAfter: failAfter)
    }

    package func stop() {
        let wasStopped = state.withLock { state -> Bool in
            defer { state.stopped = true }
            return state.stopped
        }
        guard !wasStopped else { return }
        wakeBlockedUnixListener(atPath: socketPath)
        close(listener)
        try? FileManager.default.removeItem(at: directory)
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
        while !buffer.contains(0x0A) {
            let count = recv(connection, &chunk, chunk.count, 0)
            guard count > 0 else { return }
            buffer.append(contentsOf: chunk[0..<count])
        }
        let line = Data(buffer[..<buffer.firstIndex(of: 0x0A)!])
        guard let json = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let id = json["id"] as? String
        else { return }
        let params = json["params"] as? [String: Any]
        let request = Request(
            method: json["method"] as? String ?? "",
            paneID: params?["pane_id"] as? String,
            text: params?["text"] as? String,
            keys: params?["keys"] as? [String]
        )
        let reply: String? = switch answer(request) {
        case .ok: #"{"id":"\#(id)","result":{"type":"ok"}}"#
        case .error(let code): #"{"id":"\#(id)","error":{"code":"\#(code)","message":"fake"}}"#
        case .hangUp: nil
        case .raw(let line): line
        }
        if let reply {
            let bytes = Array((reply + "\n").utf8)
            _ = bytes.withUnsafeBufferPointer { pointer in
                send(connection, pointer.baseAddress, pointer.count, POSIXSocket.sendFlags)
            }
        }
        let ready = state.withLock { state -> [BoundedWait] in
            state.requests.append(request)
            let requests = state.requests
            let reached = state.watches.filter { $0.reached(requests) }.map(\.wait)
            state.watches.removeAll { $0.reached(requests) }
            return reached
        }
        for wait in ready { wait.resolve() }
    }
}
