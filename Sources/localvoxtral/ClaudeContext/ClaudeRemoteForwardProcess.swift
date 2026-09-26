import Foundation

/// One long-lived `ssh -N -R` process, as a seam.
///
/// A protocol rather than `Process` for the reason the backend supervisor
/// cannot claim: that one spawns a local binary a test can write itself, while
/// this one spawns **ssh against a real host**. No unit test may do that — not
/// slowly, not flakily, not at all — so the process is injected and the tests
/// drive a fake.
public enum ClaudeRemoteForwardExitStatus: Sendable, Equatable {
    case code(Int32)
    /// The process-exit notification did not expose a status, and reaping here
    /// would violate the local forward's PID/PGID lifetime invariant.
    case unavailable

    var logDescription: String {
        switch self {
        case .code(let status): return String(status)
        case .unavailable: return "unavailable"
        }
    }
}

public protocol ClaudeRemoteForwardProcess: Sendable {
    /// Cheap liveness used before reusing an app-held local forward.
    var isRunning: Bool { get }
    /// stderr, line by line, finishing when the process does.
    ///
    /// stderr is not diagnostics here, it is the PRODUCT: `remote port
    /// forwarding failed` is the only thing that distinguishes "another machine
    /// holds this port" from any other reason ssh exited.
    var standardErrorLines: AsyncStream<String> { get }
    /// Resumes with the exit status once the process ends, or an honest
    /// unavailable value when observation and collection must stay separate.
    func waitUntilExit() async -> ClaudeRemoteForwardExitStatus
    /// Ask it to stop (SIGTERM). Must be safe to call more than once, and after
    /// exit.
    func terminate()
    /// Make it stop (SIGKILL), for a process that ignored `terminate()`. Same
    /// safety contract: idempotent, and harmless after exit.
    ///
    /// Separate from `terminate()` because the supervisor must be able to
    /// ESCALATE. An ssh that is wedged — a dead network with unacked data in
    /// flight, a host that stopped answering — holds the remote bind and this
    /// Mac's file descriptors, and asking it politely a second time achieves
    /// nothing.
    func forceTerminate()
}
