import ClaudeContextWire
import Dispatch
import Foundation
import Synchronization

/// `/v1/doctor` on the remote listener (#910): the Mac's half of a remote
/// host's `localvoxtral doctor`. Authenticated like a hook, before this is
/// reached, and it answers only the host-safe checks
/// (`AgentCLIDoctorChecks.hostChecks`) for the host whose token asked: no
/// local path, no other host, nothing about this Mac's agents.
///
/// The body is the numbered text a person reads, or with
/// `Accept: application/json`, the `AgentCLIResponse` the Mac's own
/// `doctor --json` prints.
public final class RemoteDoctorRoute: Sendable {
    public static let path = "/v1/doctor"

    private let checks: @Sendable (_ hostID: String) async -> [AgentCLICheck]
    private let timeout: TimeInterval

    /// - Parameters:
    ///   - timeout: how long the connection's thread waits for the app. The
    ///     checks list Claude Code's and Codex's plugins (1–3 s each).
    ///   - checks: the host-safe checks for an enrolled host id.
    public init(
        timeout: TimeInterval = 8,
        checks: @escaping @Sendable (_ hostID: String) async -> [AgentCLICheck]
    ) {
        self.timeout = timeout
        self.checks = checks
    }

    public enum Answer: Equatable, Sendable {
        case body(Data, contentType: String)
        case timedOut
    }

    /// Blocks the calling connection thread, never the main one, until the
    /// app answers or `timeout` passes.
    func answer(hostID: String, json: Bool) -> Answer {
        let result = Mutex<[AgentCLICheck]?>(nil)
        let done = DispatchSemaphore(value: 0)
        let checks = self.checks
        Task {
            let answer = await checks(hostID)
            result.withLock { $0 = answer }
            done.signal()
        }
        guard done.wait(timeout: .now() + timeout) == .success, let found = result.withLock({ $0 }) else {
            return .timedOut
        }
        let doctor = AgentCLIDoctor(checks: found)
        if json {
            let line = AgentCLIWire.encodeLine(AgentCLIResponse(doctor: doctor)) ?? Data()
            return .body(line, contentType: "application/json")
        }
        let text = (doctor.textLines() + ["", doctor.summaryLine]).map { $0 + "\n" }.joined()
        return .body(Data(text.utf8), contentType: "text/plain; charset=utf-8")
    }
}
