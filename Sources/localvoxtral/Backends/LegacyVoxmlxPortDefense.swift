import Darwin
import Foundation
import Synchronization

struct ListeningProcess: Equatable, Sendable {
    let pid: pid_t
    let executableURL: URL
}

enum LegacyVoxmlxPortOutcome: Equatable, Sendable {
    case available
    case terminatedLegacy(ListeningProcess)
    case occupiedByOther(ListeningProcess)
}

protocol LegacyVoxmlxPortDefending: Sendable {
    func clearLegacyOccupantIfNeeded(port: Int) async -> LegacyVoxmlxPortOutcome
}

struct LegacyVoxmlxPortDefense: LegacyVoxmlxPortDefending {
    typealias OccupantProbe = @Sendable (Int) -> ListeningProcess?
    typealias Terminate = @Sendable (pid_t) -> Bool

    private let layout: BackendInstallLayout
    private let occupantProbe: OccupantProbe
    private let terminate: Terminate

    init(
        layout: BackendInstallLayout = BackendInstallLayout(),
        occupantProbe: @escaping OccupantProbe = Self.defaultOccupantProbe,
        terminate: @escaping Terminate = Self.defaultTerminate
    ) {
        self.layout = layout
        self.occupantProbe = occupantProbe
        self.terminate = terminate
    }

    func clearLegacyOccupantIfNeeded(port: Int) async -> LegacyVoxmlxPortOutcome {
        guard let occupant = await Task.detached(priority: .utility, operation: {
            occupantProbe(port)
        }).value else {
            return .available
        }

        guard Self.isProvablyLegacyVoxmlx(
            executableURL: occupant.executableURL,
            installRoot: layout.root
        ) else {
            Log.backends.error(
                "Port \(port, privacy: .public) is occupied by pid=\(occupant.pid, privacy: .public) at \(occupant.executableURL.path, privacy: .public); refusing to terminate an unowned process."
            )
            return .occupiedByOther(occupant)
        }

        let terminated = await Task.detached(priority: .utility) {
            terminate(occupant.pid)
        }.value
        guard terminated else {
            Log.backends.error(
                "Retired voxmlx pid=\(occupant.pid, privacy: .public) occupies port \(port, privacy: .public) but could not be terminated."
            )
            return .occupiedByOther(occupant)
        }
        Log.backends.notice(
            "Terminated retired voxmlx pid=\(occupant.pid, privacy: .public) before starting speechd on port \(port, privacy: .public)."
        )
        return .terminatedLegacy(occupant)
    }

    static func isProvablyLegacyVoxmlx(executableURL: URL, installRoot: URL) -> Bool {
        let executable = executableURL.standardizedFileURL.path
        let toolsRoot = installRoot
            .appendingPathComponent("tools", isDirectory: true)
            .appendingPathComponent("voxmlx", isDirectory: true)
            .standardizedFileURL.path
        let toolsPrefix = toolsRoot.hasSuffix("/") ? toolsRoot : toolsRoot + "/"
        if executable.hasPrefix(toolsPrefix) { return true }

        let legacyEntryPoint = installRoot
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("voxmlx-serve")
            .standardizedFileURL.path
        return executable == legacyEntryPoint
    }

    private static func defaultOccupantProbe(port: Int) -> ListeningProcess? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-nP", "-a", "-iTCP:\(port)", "-sTCP:LISTEN", "-t"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        let lines = Mutex<[String]>([])
        let reader = PipeLineReader(fileHandle: output.fileHandleForReading) { line in
            lines.withLock { $0.append(line) }
        }
        do {
            try process.run()
            reader.start()
            process.waitUntilExit()
            output.fileHandleForWriting.closeFile()
            reader.waitUntilFinished()
        } catch {
            Log.backends.error(
                "Failed to inspect listener on port \(port, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }

        guard let pidText = lines.withLock({ $0.first }),
              let pid = pid_t(pidText.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return nil }

        // Darwin's PROC_PIDPATHINFO_MAXSIZE macro is 4 * MAXPATHLEN but is not
        // imported into Swift because it is an expression-style C macro.
        var pathBuffer = [CChar](repeating: 0, count: 4_096)
        let length = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
        guard length > 0 else {
            return ListeningProcess(pid: pid, executableURL: URL(fileURLWithPath: "<unknown>"))
        }
        let pathBytes = pathBuffer
            .prefix { $0 != 0 }
            .map { UInt8(bitPattern: $0) }
        return ListeningProcess(
            pid: pid,
            executableURL: URL(fileURLWithPath: String(decoding: pathBytes, as: UTF8.self))
        )
    }

    private static func defaultTerminate(pid: pid_t) -> Bool {
        guard Darwin.kill(pid, SIGTERM) == 0 else { return false }
        // Do not race speechd against the stale listener releasing 8471.
        // Failure to exit stays a normal conflict; never escalate to SIGKILL.
        for _ in 0..<20 {
            if Darwin.kill(pid, 0) != 0, errno == ESRCH { return true }
            usleep(100_000)
        }
        return false
    }
}

extension LegacyVoxmlxPortDefense: @unchecked Sendable {}
