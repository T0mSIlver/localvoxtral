import Foundation

#if canImport(Darwin)
import Darwin

/// Is a herdr client (app-mode `herdr` process) attached to this TTY device?
/// This is what binds "Ghostty's focused surface" to "herdr is what that
/// surface displays" — the socket API has no client introspection.
protocol HerdrClientTTYProbing: Sendable {
    func isHerdrClient(onTTYDevicePath: String) -> Bool
}

/// Same-user process-table probe used only after Ghostty positively identifies
/// its focused surface's TTY. Every metadata failure abstains; absence is safer
/// than treating an unrelated or unreadable surface as herdr.
enum HerdrClientTTYProbe {
    static func isHerdrClient(onTTYDevicePath path: String) -> Bool {
        isHerdrClient(
            onTTYDevicePath: path,
            deviceID: liveDeviceID,
            processNames: liveProcessNames
        )
    }

    static func isHerdrClient(
        onTTYDevicePath path: String,
        deviceID: @Sendable (String) -> dev_t?,
        processNames: @Sendable (dev_t) -> [String]?
    ) -> Bool {
        guard let device = deviceID(path),
              let names = processNames(device)
        else { return false }
        return names.contains("herdr")
    }

    /// Both live reads are the SHARED walk (`TTYProcessTable`), so this probe
    /// and the ssh-destination probe cannot drift apart on what "on this tty"
    /// means. The injected-seam signatures above are unchanged: this one only
    /// ever needs names, and says so by throwing the pids away here.
    private static let liveDeviceID: @Sendable (String) -> dev_t? = TTYProcessTable.liveDeviceID

    private static let liveProcessNames: @Sendable (dev_t) -> [String]? = { device in
        TTYProcessTable.entries(onDevice: device)?.map(\.name)
    }

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
    static func clientSurfaceCount() -> Int? {
        clientSurfaceCount(processes: TTYProcessTable.allProcesses())
    }

    static func clientSurfaceCount(processes: [TTYProcessTable.Entry]?) -> Int? {
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
