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

/// Is a whole-view herdr client (app-mode `herdr` process) in the foreground
/// of this TTY device?
/// This is what binds "Ghostty's focused surface" to "herdr is what that
/// surface displays" — the socket API has no client introspection.
package protocol HerdrClientTTYProbing: Sendable {
    func isHerdrClient(onTTYDevicePath: String) -> Bool
}

/// Same-user process-table probe used only after Ghostty positively identifies
/// its focused surface's TTY. Every metadata failure abstains; absence is safer
/// than treating an unrelated or unreadable surface as herdr.
package enum HerdrClientTTYProbe {
    package static func isHerdrClient(onTTYDevicePath path: String) -> Bool {
        isHerdrClient(
            onTTYDevicePath: path,
            deviceID: liveDeviceID,
            processes: TTYProcessTable.entries(onDevice:),
            arguments: SSHDestinationTTYProbe.processArguments(pid:)
        )
    }

    package static func isHerdrClient(
        onTTYDevicePath path: String,
        deviceID: @Sendable (String) -> dev_t?,
        processes: @Sendable (dev_t) -> [TTYProcessTable.Entry]?,
        arguments: (Int32) -> [String]?
    ) -> Bool {
        guard let device = deviceID(path),
              let entries = processes(device)
        else { return false }
        // The client must be the job the terminal gives its input to. A
        // suspended client (Ctrl-Z) keeps the tty while its shell is what the
        // surface shows, and the inner agent it hides still passes every pane
        // check (#1602).
        let clients = entries.filter {
            $0.name == "herdr" && $0.processGroupID > 0 && $0.processGroupID == $0.terminalForegroundGroupID
        }
        // Every herdr process in that job must be a whole-view client, by the
        // classifier the remote arm applies to an ssh command. The arms read
        // the server's one focused pane; `herdr terminal attach <id>` shows
        // ONE pane without moving that focus, and `herdr --remote` shows another
        // server, so either would bind a pane the surface does not show.
        // Unreadable argv refuses.
        return !clients.isEmpty && clients.allSatisfy { client in
            guard let argv = arguments(client.pid),
                  case .plainClient = SSHDestinationTTYProbe.classifyHerdrCommand(argv)
            else { return false }
            return true
        }
    }

    /// Both live reads are the SHARED walk (`TTYProcessTable`), so this probe
    /// and the ssh-destination probe cannot drift apart on what "on this tty"
    /// means.
    private static let liveDeviceID: @Sendable (String) -> dev_t? = TTYProcessTable.liveDeviceID

    /// How many terminal surfaces this user has a herdr client on, or nil when
    /// the process table cannot be walked.
    ///
    /// A herdr server is a detached daemon (`setsid`, no controlling terminal),
    /// so what this counts is clients. The unit is a JOB on a terminal device,
    /// not a process and not a device: a client's own child processes share its
    /// process group and count once, while two clients sharing one terminal —
    /// suspend the first, start the second — are the two surfaces they are.
    ///
    /// One caller, the local herdr arm: herdr keeps ONE machine selection per
    /// user rather than one per client, so with a second client on screen that
    /// selection cannot say which machine the focused surface is showing
    /// (issue #286). Only the count matters, never which job.
    package static func clientSurfaceCount() -> Int? {
        clientSurfaceCount(processes: TTYProcessTable.allProcesses())
    }

    package static func clientSurfaceCount(processes: [TTYProcessTable.Entry]?) -> Int? {
        guard let processes else { return nil }
        let user = geteuid()
        let jobs = processes.lazy
            .filter { $0.name == "herdr" && $0.effectiveUserID == user }
            .compactMap { entry in
                entry.ttyDevice.map { ClientJob(device: $0, processGroupID: entry.processGroupID) }
            }
        return Set(jobs).count
    }

    private struct ClientJob: Hashable {
        var device: dev_t
        var processGroupID: Int32
    }
}
#endif
