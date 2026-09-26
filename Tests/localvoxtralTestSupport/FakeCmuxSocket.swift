import Foundation
import localvoxtralCore
import Synchronization
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// cmux's control socket as the app sees it (#727): an AF_UNIX listener
/// speaking cmux's line protocol, one connection at a time, many in a row.
/// It answers `auth.login`, `system.tree` (one terminal surface, focused or
/// not), `surface.send_text` and `surface.send_key`, and records every
/// write. A `CmuxSocketClient` dials it through `client(password:)`, which
/// injects the peer checks a test process cannot pass for real.
package final class FakeCmuxSocket: @unchecked Sendable {
    /// How cmux answers a write.
    package enum WriteAnswer: Sendable {
        /// `ok` with `queued`, or with no `queued` field (an older cmux).
        case accepted(queued: Bool?)
        case error(code: String)
        /// Reads the request and closes without a word.
        case noAnswer
    }

    package struct Write: Sendable, Equatable {
        package var method: String
        package var surfaceID: String?
        package var text: String?
        package var key: String?

        package init(method: String, surfaceID: String? = nil, text: String? = nil, key: String? = nil) {
            self.method = method
            self.surfaceID = surfaceID
            self.text = text
            self.key = key
        }
    }

    package static let pid: pid_t = 4242
    package let surfaceID = "22222222-2222-2222-2222-222222222222"
    package let otherSurfaceID = "99999999-9999-9999-9999-999999999999"
    package let tty: String
    package let socketPath: String

    private struct State {
        var writes: [Write] = []
        var watches: [(reached: @Sendable ([Write]) -> Bool, wait: BoundedWait)] = []
        var surfaceIsFocused = true
        var stopped = false
    }

    private let listener: Int32
    private let directory: URL
    private let answer: @Sendable (Write) -> WriteAnswer
    private let state = Mutex(State())

    package init(
        tty: String = "/dev/ttys042",
        answer: @escaping @Sendable (Write) -> WriteAnswer = { _ in .accepted(queued: false) }
    ) throws {
        self.tty = tty
        self.answer = answer
        directory = URL(fileURLWithPath: "/tmp/lvx-fcmux-\(UUID().uuidString.prefix(8))")
        socketPath = directory.appendingPathComponent("cmux.sock").path
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
        )
        let descriptor = socket(AF_UNIX, POSIXSocket.stream, 0)
        guard descriptor >= 0 else { throw POSIXError(.ENFILE) }
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

    /// A client that dials only this socket and takes it for the cmux app
    /// `FakeCmuxSocket.pid`.
    package func client(password: String? = "hunter2") -> CmuxSocketClient {
        CmuxSocketClient(
            socketPaths: [socketPath],
            password: { password },
            timeout: 5,
            peerPID: { _ in Self.pid },
            bundleIDOfRunningPID: { _ in TerminalScreenAllowlist.cmuxBundleID }
        )
    }

    /// Whether `system.tree` reports the surface as focused, or another one.
    package func setSurfaceFocused(_ focused: Bool) {
        state.withLock { $0.surfaceIsFocused = focused }
    }

    package var writes: [Write] { state.withLock { $0.writes } }

    /// Every `surface.send_text` text, joined in arrival order.
    package var sentText: String {
        writes.filter { $0.method == "surface.send_text" }.compactMap(\.text).joined()
    }

    /// True once the writes so far satisfy `reached`; false if they did not
    /// within `failAfter` seconds of wall time.
    package func waitUntil(
        failAfter: TimeInterval = 10,
        isolation: isolated (any Actor)? = #isolation,
        _ reached: @escaping @Sendable ([Write]) -> Bool
    ) async -> Bool {
        let wait = BoundedWait()
        let already = state.withLock { state -> Bool in
            if reached(state.writes) { return true }
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
            POSIXSocket.suppressSIGPIPE(onSocket: connection)
            handle(connection)
            close(connection)
        }
    }

    private func handle(_ connection: Int32) {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while buffer.count <= 256 * 1024 {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[buffer.startIndex..<newline])
                buffer = Data(buffer[buffer.index(after: newline)...])
                guard let reply = reply(to: line), send(reply, on: connection) else { return }
                continue
            }
            let count = LibC.read(connection, &chunk, chunk.count)
            guard count > 0 else { return }
            buffer.append(contentsOf: chunk[0..<count])
        }
    }

    private func reply(to line: Data) -> Data? {
        guard let request = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let id = request["id"] as? String,
              let method = request["method"] as? String
        else { return nil }
        let params = request["params"] as? [String: Any] ?? [:]
        switch method {
        case "auth.login":
            return Self.line(["id": id, "ok": true, "result": ["authenticated": true]])
        case "system.tree":
            return Self.line(["id": id, "ok": true, "result": tree()])
        case "surface.send_text", "surface.send_key":
            let write = Write(
                method: method,
                surfaceID: params["surface_id"] as? String,
                text: params["text"] as? String,
                key: params["key"] as? String
            )
            let answer = answer(write)
            record(write)
            switch answer {
            case .accepted(let queued):
                var result: [String: Any] = ["surface_id": write.surfaceID ?? surfaceID, "surface_ref": "surface:2"]
                if let queued { result["queued"] = queued }
                return Self.line(["id": id, "ok": true, "result": result])
            case .error(let code):
                return Self.line(["id": id, "ok": false, "error": ["code": code, "message": "no"]])
            case .noAnswer:
                return nil
            }
        default:
            return Self.line(["id": id, "ok": false, "error": ["code": "method_not_found", "message": "no"]])
        }
    }

    private func record(_ write: Write) {
        let ready = state.withLock { state -> [BoundedWait] in
            state.writes.append(write)
            let writes = state.writes
            let reached = state.watches.filter { $0.reached(writes) }.map(\.wait)
            state.watches.removeAll { $0.reached(writes) }
            return reached
        }
        for wait in ready { wait.resolve() }
    }

    /// One window, one workspace, one pane with the joined surface and
    /// another; `active` names whichever is focused.
    private func tree() -> [String: Any] {
        let focused = state.withLock { $0.surfaceIsFocused }
        let surfaces: [[String: Any]] = [
            ["id": otherSurfaceID, "type": "terminal", "focused": !focused, "tty": "/dev/ttys999"],
            ["id": surfaceID, "type": "terminal", "focused": focused, "tty": tty],
        ]
        return [
            "active": ["surface_id": focused ? surfaceID : otherSurfaceID],
            "windows": [["workspaces": [["panes": [["surfaces": surfaces]]]]]],
        ]
    }

    private static func line(_ object: [String: Any]) -> Data? {
        guard var data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        data.append(0x0A)
        return data
    }

    private func send(_ data: Data, on connection: Int32) -> Bool {
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return false }
            var offset = 0
            while offset < raw.count {
                let count = LibC.send(connection, base.advanced(by: offset), raw.count - offset, POSIXSocket.sendFlags)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { return false }
                offset += count
            }
            return true
        }
    }
}
