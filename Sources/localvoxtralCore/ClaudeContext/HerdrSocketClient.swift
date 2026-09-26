import Foundation

#if canImport(Darwin) || canImport(Glibc)
#if canImport(Darwin)
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
#else
import Glibc
#endif

/// What the resolver needs to know about herdr's focused pane.
package struct HerdrFocusedPane: Sendable, Equatable {
    package var paneID: String
    /// herdr's own Claude-session claim for the pane, when its integration is
    /// installed: (kind "id" → sessionID). nil when absent or kind == "path".
    package var claimedClaudeSessionID: String?

    // Deliberately no `terminal_title`. herdr does report the inner pane's
    // captured OSC 2 title, and the remote arm used to require a
    // broker-allocated marker in it as a second binding. Nothing reads a
    // window title for a join any more (owner decision 2026-09-05), so the
    // field is not decoded at all — an undecoded field cannot become an
    // accidental input.

    package init(paneID: String, claimedClaudeSessionID: String?) {
        self.paneID = paneID
        self.claimedClaudeSessionID = claimedClaudeSessionID
    }
}

/// One process herdr reports as foreground in a pane.
package struct HerdrForegroundProcess: Sendable, Equatable {
    package var pid: Int32
    /// nil ⇒ herdr did not report a name for this process. Never inferred.
    package var name: String?

    package init(pid: Int32, name: String? = nil) {
        self.pid = pid
        self.name = name
    }
}

package struct HerdrPaneForegroundInfo: Sendable, Equatable {
    package var shellPID: Int32?
    /// nil ⇒ the `foreground_processes` key was ABSENT (detection unavailable);
    /// distinct from [] which cannot occur on the wire.
    package var foregroundProcesses: [HerdrForegroundProcess]?

    /// The local arm's question: is the pid we registered running here? Derived
    /// rather than stored, so a pid list and a process list can never disagree.
    package var foregroundPIDs: [Int32]? { foregroundProcesses?.map(\.pid) }

    package init(shellPID: Int32?, foregroundProcesses: [HerdrForegroundProcess]?) {
        self.shellPID = shellPID
        self.foregroundProcesses = foregroundProcesses
    }

    /// Pid-only convenience for the local arm and its tests, which have no
    /// business knowing process names: a REMOTE session's pid means nothing
    /// here (it is another machine's namespace), so that arm identifies the
    /// agent by name instead and this init makes the asymmetry explicit.
    package init(shellPID: Int32?, foregroundPIDs: [Int32]?) {
        self.init(
            shellPID: shellPID,
            foregroundProcesses: foregroundPIDs?.map { HerdrForegroundProcess(pid: $0) }
        )
    }
}

package protocol HerdrPaneQuerying: Sendable {
    func focusedPane(socketPath: String) async -> HerdrFocusedPane?
    func paneForegroundInfo(socketPath: String, paneID: String) async -> HerdrPaneForegroundInfo?
    /// The visible text of exactly `paneID` (`pane.read`, ANSI-stripped by the
    /// server). Raw wire text: the caller owns sanitization, bounding, and
    /// every consent gate. nil on any refusal, failure, or invalid response.
    func paneVisibleText(socketPath: String, paneID: String) async -> String?
}

/// The two calls that write into a herdr pane (#726), and nothing else: no
/// `pane.run`, no other key. Wire shapes from herdr 0.9.0
/// (`src/api/schema/panes.rs`, `src/app/api/panes.rs`). Read
/// docs/agent/invariants.md ("The app writes into an agent only through
/// three routes") before adding a third.
package protocol HerdrPaneWriting: Sendable {
    /// `pane.send_text`: the bytes of `text` into the pane's input, as-is.
    /// herdr applies no bracketed paste to it, so the caller must never pass
    /// a control character. True only when herdr answered `ok`.
    func sendText(socketPath: String, paneID: String, text: String) async -> Bool
    /// `pane.send_keys` with exactly `["enter"]`. True only on `ok`.
    func pressEnter(socketPath: String, paneID: String) async -> Bool
}

/// Minimal capability-bounded client for herdr's one-request-per-connection
/// JSON API. Reads are limited to the focused/joined pane; the mutations are
/// the short-lived `lvmark` panel token used by remote surface authorization
/// and the two `HerdrPaneWriting` calls, which only the dictation's herdr
/// route makes.
///
/// Every syscall shares one absolute monotonic deadline. A per-phase timeout
/// would let a slow connect, write, and response each consume the whole budget,
/// while a per-read timeout would let a trickling peer retain the task forever.
package struct HerdrSocketClient: HerdrPaneQuerying, HerdrPanelMetadataReporting, HerdrPaneWriting {
    /// Per-request observation: method name, latency in seconds, success, and
    /// — on failure only — the server's error payload verbatim
    /// (`"<code>: <message>"`, content-free) or a local failure cause
    /// (`"no-response"`, `"invalid-response"`). Never carries pane ids,
    /// socket paths, or response bodies.
    package typealias LatencyReport = @Sendable (_ method: String, _ latencySeconds: TimeInterval, _ success: Bool, _ detail: String) -> Void

    private let timeout: TimeInterval
    private let uptimeNanos: @Sendable () -> UInt64
    private let socketMetadata: @Sendable (String) -> ClaudeSocketGuard.PathMetadata?
    private let latencyRecorder: LatencyReport?

    /// - Parameter socketMetadata: injectable so the ownership refusal is
    ///   testable — a real foreign-uid socket cannot be created from a
    ///   single-user test process.
    /// - Parameter latencyRecorder: test/field observation of per-request
    ///   latency and refusal payloads. Nil in production paths that do not
    ///   record; the client still logs completions and failures loudly
    ///   through `Log.claudeContext` (never silent — silent failure paths
    ///   have cost hours of remote probing).
    package init(
        timeout: TimeInterval = 0.5,
        uptimeNanos: @escaping @Sendable () -> UInt64 = {
            DispatchTime.now().uptimeNanoseconds
        },
        socketMetadata: @escaping @Sendable (String) -> ClaudeSocketGuard.PathMetadata? = {
            ClaudeSocketGuard.metadata(ofPath: $0)
        },
        latencyRecorder: LatencyReport? = nil
    ) {
        self.timeout = timeout
        self.uptimeNanos = uptimeNanos
        self.socketMetadata = socketMetadata
        self.latencyRecorder = latencyRecorder
    }

    package func focusedPane(socketPath: String) async -> HerdrFocusedPane? {
        await Task.detached(priority: .userInitiated) { [self] in
            let startNanos = uptimeNanos()
            let request = Request(
                id: Self.requestID(), method: "pane.current", params: [String: String]()
            )
            guard let line = query(socketPath: socketPath, request: request) else {
                noteLatency(method: "pane.current", startNanos: startNanos, success: false, detail: "no-response")
                Log.claudeContext.info("Herdr focused-pane query abstained: invalid response")
                return nil
            }
            guard let envelope = try? JSONDecoder().decode(
                    Envelope<PaneCurrentResult>.self, from: line
                  ),
                  envelope.id == request.id,
                  let result = envelope.result,
                  result.type == "pane_current",
                  result.pane.focused
            else {
                let detail = Self.errorPayload(from: line) ?? "invalid-response"
                noteLatency(method: "pane.current", startNanos: startNanos, success: false, detail: detail)
                Log.claudeContext.info("Herdr focused-pane query abstained: invalid response")
                return nil
            }
            noteLatency(method: "pane.current", startNanos: startNanos, success: true, detail: "ok")
            let claim = result.pane.agentSession.flatMap {
                $0.kind == "id" ? $0.value : nil
            }
            return HerdrFocusedPane(
                paneID: result.pane.paneID,
                claimedClaudeSessionID: claim
            )
        }.value
    }

    package func paneForegroundInfo(
        socketPath: String,
        paneID: String
    ) async -> HerdrPaneForegroundInfo? {
        await Task.detached(priority: .userInitiated) { [self] in
            let startNanos = uptimeNanos()
            let request = Request(
                id: Self.requestID(),
                method: "pane.process_info",
                params: ["pane_id": paneID]
            )
            guard let line = query(socketPath: socketPath, request: request) else {
                noteLatency(method: "pane.process_info", startNanos: startNanos, success: false, detail: "no-response")
                Log.claudeContext.info("Herdr foreground-process query abstained: invalid response")
                return nil
            }
            guard let envelope = try? JSONDecoder().decode(
                    Envelope<PaneProcessInfoResult>.self, from: line
                  ),
                  envelope.id == request.id,
                  let result = envelope.result,
                  result.type == "pane_process_info",
                  result.processInfo.paneID == paneID
            else {
                let detail = Self.errorPayload(from: line) ?? "invalid-response"
                noteLatency(method: "pane.process_info", startNanos: startNanos, success: false, detail: detail)
                Log.claudeContext.info("Herdr foreground-process query abstained: invalid response")
                return nil
            }
            noteLatency(method: "pane.process_info", startNanos: startNanos, success: true, detail: "ok")
            return HerdrPaneForegroundInfo(
                shellPID: result.processInfo.shellPID,
                foregroundProcesses: result.processInfo.foregroundProcesses?.map {
                    HerdrForegroundProcess(pid: $0.pid, name: $0.name)
                }
            )
        }.value
    }

    package func paneVisibleText(socketPath: String, paneID: String) async -> String? {
        await Task.detached(priority: .userInitiated) { [self] in
            let startNanos = uptimeNanos()
            let request = Request(
                id: Self.requestID(),
                method: "pane.read",
                params: PaneReadParams(paneID: paneID)
            )
            guard let line = query(socketPath: socketPath, request: request) else {
                noteLatency(method: "pane.read", startNanos: startNanos, success: false, detail: "no-response")
                Log.claudeContext.info("Herdr pane read abstained: invalid response")
                return nil
            }
            guard let envelope = try? JSONDecoder().decode(
                    Envelope<PaneReadResult>.self, from: line
                  ),
                  envelope.id == request.id,
                  let result = envelope.result,
                  result.type == "pane_read",
                  // The response must be about the pane that was asked for. A
                  // server answering about any other pane is invalid, and its
                  // text must never be attributed to the joined pane.
                  result.read.paneID == paneID
            else {
                // Never log the raw line here: a pane.read body carries the
                // user's terminal text. Only the server's error envelope
                // (code + message, content-free) is safe to record verbatim.
                let detail = Self.errorPayload(from: line) ?? "invalid-response"
                noteLatency(method: "pane.read", startNanos: startNanos, success: false, detail: detail)
                Log.claudeContext.info("Herdr pane read abstained: invalid response")
                return nil
            }
            noteLatency(method: "pane.read", startNanos: startNanos, success: true, detail: "ok")
            return result.read.text
        }.value
    }

    package func reportPanelToken(
        socketPath: String,
        paneID: String,
        value: String?,
        ttlMilliseconds: Int?
    ) async -> Bool {
        await Task.detached(priority: .userInitiated) { [self] in
            let startNanos = uptimeNanos()
            let request = Request(
                id: Self.requestID(),
                method: "pane.report_metadata",
                params: PaneReportMetadataParams(
                    paneID: paneID,
                    tokens: ["lvmark": value],
                    ttlMilliseconds: ttlMilliseconds
                )
            )
            guard let line = query(socketPath: socketPath, request: request) else {
                noteLatency(method: "pane.report_metadata", startNanos: startNanos, success: false, detail: "no-response")
                Log.claudeContext.info("Herdr panel metadata report abstained: invalid response")
                return false
            }
            guard let envelope = try? JSONDecoder().decode(Envelope<OKResult>.self, from: line),
                  envelope.id == request.id,
                  envelope.result?.type == "ok"
            else {
                let detail = Self.errorPayload(from: line) ?? "invalid-response"
                noteLatency(method: "pane.report_metadata", startNanos: startNanos, success: false, detail: detail)
                Log.claudeContext.info("Herdr panel metadata report abstained: invalid response")
                return false
            }
            noteLatency(method: "pane.report_metadata", startNanos: startNanos, success: true, detail: "ok")
            return true
        }.value
    }

    package func sendText(socketPath: String, paneID: String, text: String) async -> Bool {
        await sendOK(
            socketPath: socketPath,
            method: "pane.send_text",
            params: ["pane_id": paneID, "text": text]
        )
    }

    package func pressEnter(socketPath: String, paneID: String) async -> Bool {
        await sendOK(
            socketPath: socketPath,
            method: "pane.send_keys",
            params: PaneSendKeysParams(paneID: paneID, keys: ["enter"])
        )
    }

    /// One write whose only success answer is `ok`. Logs the method and the
    /// outcome, never the pane id or the text.
    private func sendOK(socketPath: String, method: String, params: some Encodable & Sendable) async -> Bool {
        await Task.detached(priority: .userInitiated) { [self] in
            let startNanos = uptimeNanos()
            let request = Request(id: Self.requestID(), method: method, params: params)
            guard let line = query(socketPath: socketPath, request: request) else {
                noteLatency(method: method, startNanos: startNanos, success: false, detail: "no-response")
                return false
            }
            guard let envelope = try? JSONDecoder().decode(Envelope<OKResult>.self, from: line),
                  envelope.id == request.id,
                  envelope.result?.type == "ok"
            else {
                let detail = Self.errorPayload(from: line) ?? "invalid-response"
                noteLatency(method: method, startNanos: startNanos, success: false, detail: detail)
                return false
            }
            noteLatency(method: method, startNanos: startNanos, success: true, detail: "ok")
            return true
        }.value
    }

    /// Record one request's outcome: always to the unified log (loud paths,
    /// no ids or paths), and additionally to the injected recorder when one
    /// is set (the lane's timing/Log capture).
    private func noteLatency(method: String, startNanos: UInt64, success: Bool, detail: String) {
        let nowNanos = uptimeNanos()
        let elapsedNanos = nowNanos >= startNanos ? nowNanos - startNanos : 0
        let elapsedSeconds = TimeInterval(elapsedNanos) / 1_000_000_000
        let elapsedMs = Int((elapsedSeconds * 1000).rounded())
        Log.claudeContext.info(
            "Herdr \(method, privacy: .public) \(success ? "completed" : "abstained", privacy: .public) in \(elapsedMs, privacy: .public) ms (\(detail, privacy: .public))"
        )
        latencyRecorder?(method, elapsedSeconds, success, detail)
    }

    /// The server's error envelope verbatim (`"<code>: <message>"`), or nil
    /// when the line is not an error envelope at all. Only error envelopes
    /// are ever recorded: success bodies carry pane ids and terminal text
    /// and must never reach a log.
    private static func errorPayload(from line: Data) -> String? {
        guard let envelope = try? JSONDecoder().decode(ErrorEnvelope.self, from: line) else {
            return nil
        }
        return "\(envelope.error.code): \(envelope.error.message)"
    }

    private func query(socketPath: String, request: some Encodable) -> Data? {
        let deadline = makeDeadline()
        guard socketPath.hasPrefix("/"),
              let metadata = socketMetadata(socketPath),
              metadata.isSocket,
              metadata.ownerUID == UInt32(getuid())
        else {
            // Outcome only: a pane id or socket path is a live join handle and
            // must never escape into the unified log.
            Log.claudeContext.info("Herdr query abstained: socket path refused")
            return nil
        }

        guard let requestLine = try? Self.encodedLine(request),
              let fd = openConnection(to: socketPath, deadline: deadline)
        else {
            Log.claudeContext.info("Herdr query abstained: connection unavailable")
            return nil
        }
        defer { close(fd) }

        guard writeAll(fd: fd, data: requestLine, deadline: deadline) else {
            Log.claudeContext.info("Herdr query abstained: request deadline or write failure")
            return nil
        }
        // The protocol is exactly one request. Half-closing makes that
        // invariant explicit without preventing the response half from being
        // read.
        shutdown(fd, Int32(SHUT_WR))
        guard let response = readLine(fd: fd, deadline: deadline) else {
            Log.claudeContext.info("Herdr query abstained: response deadline, framing, or size failure")
            return nil
        }
        return response
    }

    private func openConnection(to socketPath: String, deadline: UInt64) -> Int32? {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        POSIXSocket.setLength(of: &address)
        let pathBytes = Array(socketPath.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard pathBytes.count < capacity else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: pathBytes)
            raw[pathBytes.count] = 0
        }

        let fd = socket(AF_UNIX, POSIXSocket.stream, 0)
        guard fd >= 0 else { return nil }
        guard makeNonBlocking(fd) else {
            close(fd)
            return nil
        }
        // A failed SO_NOSIGPIPE is fatal to the CALLER, not just this query: a
        // peer closing mid-write would then SIGPIPE the whole app (the same
        // class of crash as the FileHandle field bug, PR #60). Abstain instead.
        // Linux has no such option; its sends pass `MSG_NOSIGNAL`.
        #if canImport(Darwin)
        var noSigPipe: Int32 = 1
        guard setsockopt(
            fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe,
            socklen_t(MemoryLayout<Int32>.size)
        ) == 0 else {
            close(fd)
            return nil
        }
        #endif

        let status = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                LibC.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if status == 0 { return fd }
        guard errno == EINPROGRESS || errno == EINTR,
              wait(fd: fd, events: Int16(POLLOUT), deadline: deadline)
        else {
            close(fd)
            return nil
        }

        // Writability also reports a failed non-blocking connect. SO_ERROR is
        // the only authoritative completion result.
        var socketError: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &length) == 0,
              socketError == 0
        else {
            close(fd)
            return nil
        }
        return fd
    }

    private func writeAll(fd: Int32, data: Data, deadline: UInt64) -> Bool {
        data.withUnsafeBytes { raw in
            // Zero-length Data has a nil baseAddress; an empty write is
            // vacuously complete, not a failure.
            if raw.isEmpty { return true }
            guard let base = raw.baseAddress else { return false }
            var offset = 0
            while offset < raw.count {
                let written = LibC.send(
                    fd, base.advanced(by: offset), raw.count - offset, POSIXSocket.sendFlags
                )
                if written > 0 {
                    offset += written
                    continue
                }
                if written < 0, errno == EINTR { continue }
                if written < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                    guard wait(fd: fd, events: Int16(POLLOUT), deadline: deadline) else {
                        return false
                    }
                    continue
                }
                return false
            }
            return true
        }
    }

    private func readLine(fd: Int32, deadline: UInt64) -> Data? {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 8 * 1024)

        while true {
            guard wait(fd: fd, events: Int16(POLLIN), deadline: deadline) else { return nil }
            // Read at most one byte beyond the advertised line cap: that byte
            // is needed to distinguish an exactly-1-MiB line followed by `\n`
            // from an oversized line, but no peer can make the buffer grow by
            // whole extra chunks past the limit.
            let remainingThroughSentinel = Self.maxResponseLineBytes + 1 - buffer.count
            guard remainingThroughSentinel > 0 else { return nil }
            let readCapacity = min(chunk.count, remainingThroughSentinel)
            let count = LibC.read(fd, &chunk, readCapacity)
            if count < 0 {
                if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { continue }
                return nil
            }
            guard count > 0 else { return nil } // A response must be newline-terminated.
            buffer.append(contentsOf: chunk[0..<count])
            if let newline = buffer.firstIndex(of: 0x0A) {
                let lineLength = buffer.distance(from: buffer.startIndex, to: newline)
                guard lineLength <= Self.maxResponseLineBytes else { return nil }
                return Data(buffer[buffer.startIndex..<newline])
            }
            guard buffer.count <= Self.maxResponseLineBytes else { return nil }
        }
    }

    private func wait(fd: Int32, events: Int16, deadline: UInt64) -> Bool {
        while true {
            let current = uptimeNanos()
            guard current < deadline else { return false }
            let remaining = deadline - current
            let roundedMillis = remaining / 1_000_000 + (remaining % 1_000_000 == 0 ? 0 : 1)
            let timeoutMillis = Int32(min(roundedMillis, UInt64(Int32.max)))
            var descriptor = pollfd(fd: fd, events: events, revents: 0)
            let ready = LibC.poll(&descriptor, 1, timeoutMillis)
            if ready < 0, errno == EINTR { continue }
            return ready > 0
        }
    }

    private func makeDeadline() -> UInt64 {
        // The live value is 500 ms. A finite defensive ceiling keeps an
        // injected infinity/NaN or absurd duration from trapping during the
        // Double→UInt64 conversion; it does not widen the production budget.
        let boundedSeconds = timeout.isFinite ? min(max(0, timeout), 60) : 0
        let duration = UInt64(boundedSeconds * 1_000_000_000)
        let (deadline, overflow) = uptimeNanos().addingReportingOverflow(duration)
        return overflow ? UInt64.max : deadline
    }

    private func makeNonBlocking(_ fd: Int32) -> Bool {
        let flags = fcntl(fd, F_GETFL, 0)
        guard flags >= 0 else { return false }
        return fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0
    }

    private static func requestID() -> String {
        "lvx-" + UUID().uuidString.lowercased()
    }

    private static func encodedLine(_ request: some Encodable) throws -> Data {
        var data = try JSONEncoder().encode(request)
        data.append(0x0A)
        return data
    }

    private static let maxResponseLineBytes = 1024 * 1024

    /// Generic over the params payload: most methods take flat string maps,
    /// but `pane.read` carries a bool (`strip_ansi`), which a `[String:
    /// String]` would silently mis-encode as a string herdr's serde rejects.
    private struct Request<Params: Encodable>: Encodable {
        var id: String
        var method: String
        /// Required even for methods with no arguments; herdr rejects a
        /// request that omits this key.
        var params: Params
    }

    /// `pane.read` params — herdr c234f221, `src/api/schema/panes.rs`
    /// (`PaneReadParams`): `pane_id` and `source` are required; `format`
    /// defaults to `text` and `strip_ansi` to `true` server-side, but both are
    /// sent explicitly because the caller DEPENDS on ANSI-free plain text.
    private struct PaneReadParams: Encodable {
        var paneID: String
        var source = "visible"
        var format = "text"
        var stripANSI = true

        enum CodingKeys: String, CodingKey {
            case paneID = "pane_id"
            case source
            case format
            case stripANSI = "strip_ansi"
        }
    }

    private struct PaneSendKeysParams: Encodable, Sendable {
        var paneID: String
        var keys: [String]

        enum CodingKeys: String, CodingKey {
            case paneID = "pane_id"
            case keys
        }
    }

    private struct PaneReportMetadataParams: Encodable {
        var paneID: String
        var source = "localvoxtral"
        var tokens: [String: String?]
        var ttlMilliseconds: Int?

        enum CodingKeys: String, CodingKey {
            case paneID = "pane_id"
            case source
            case tokens
            case ttlMilliseconds = "ttl_ms"
        }
    }

    private struct Envelope<Result: Decodable>: Decodable {
        var id: String
        var result: Result?

        enum CodingKeys: String, CodingKey { case id, result, error }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            let hasResult = container.contains(.result)
            let hasError = container.contains(.error)
            guard hasResult != hasError else {
                throw DecodingError.dataCorruptedError(
                    forKey: .result,
                    in: container,
                    debugDescription: "expected exactly one of result or error"
                )
            }
            if hasError {
                _ = try container.decode(ErrorBody.self, forKey: .error)
                result = nil
            } else {
                result = try container.decode(Result.self, forKey: .result)
            }
        }
    }

    private struct ErrorBody: Decodable {
        var code: String
        var message: String
    }

    /// Error-only envelope for verbatim refusal logging. Decodes ONLY
    /// responses carrying `error`; a success body never matches (its `error`
    /// key is absent and required here), so success payloads cannot leak
    /// through this path.
    private struct ErrorEnvelope: Decodable {
        var id: String
        var error: ErrorBody
    }

    private struct OKResult: Decodable {
        var type: String
    }

    private struct PaneCurrentResult: Decodable {
        var type: String
        var pane: Pane
    }

    private struct Pane: Decodable {
        var paneID: String
        var focused: Bool
        var agentSession: AgentSession?

        enum CodingKeys: String, CodingKey {
            case paneID = "pane_id"
            case focused
            case agentSession = "agent_session"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            paneID = try container.decode(String.self, forKey: .paneID)
            focused = try container.decode(Bool.self, forKey: .focused)
            agentSession = container.contains(.agentSession)
                ? try container.decode(AgentSession.self, forKey: .agentSession)
                : nil
        }
    }

    private struct AgentSession: Decodable {
        var kind: String
        var value: String
    }

    private struct PaneProcessInfoResult: Decodable {
        var type: String
        var processInfo: ProcessInfo

        enum CodingKeys: String, CodingKey {
            case type
            case processInfo = "process_info"
        }
    }

    private struct ProcessInfo: Decodable {
        var paneID: String
        var shellPID: Int32?
        var foregroundProcesses: [ForegroundProcess]?

        enum CodingKeys: String, CodingKey {
            case paneID = "pane_id"
            case shellPID = "shell_pid"
            case foregroundProcesses = "foreground_processes"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            paneID = try container.decode(String.self, forKey: .paneID)
            shellPID = try container.decodeIfPresent(Int32.self, forKey: .shellPID)
            // Presence is meaningful: absent means herdr could not detect a
            // foreground set. A present null is not the documented wire shape
            // and must not be silently upgraded into the same state.
            foregroundProcesses = container.contains(.foregroundProcesses)
                ? try container.decode([ForegroundProcess].self, forKey: .foregroundProcesses)
                : nil
        }
    }

    private struct ForegroundProcess: Decodable {
        var pid: Int32
        /// herdr's `name` for the process (`pane.process_info`). The REMOTE
        /// herdr arm identifies the agent by this, because a remote pid is a
        /// number in another machine's namespace.
        var name: String?
    }

    /// `pane.read` success — herdr c234f221, `src/api/schema/response.rs`
    /// (`ResponseResult::PaneRead`, tag `pane_read`) wrapping
    /// `PaneReadResult` from `src/api/schema/panes.rs`. Only the fields the
    /// caller validates or consumes are decoded.
    private struct PaneReadResult: Decodable {
        var type: String
        var read: Read

        struct Read: Decodable {
            var paneID: String
            var text: String

            enum CodingKeys: String, CodingKey {
                case paneID = "pane_id"
                case text
            }
        }
    }
}
#endif
