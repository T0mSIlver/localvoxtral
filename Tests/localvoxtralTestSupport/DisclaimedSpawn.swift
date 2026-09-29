import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Runs a program as its own responsible process, as Terminal runs a shell.
///
/// macOS attributes a child's TCC and service requests to the "responsible"
/// process, which for a child of xctest under the Actions runner is the
/// anonymous xctest. Under it, `say -v ?` listed only the built-in voices
/// (#960). `responsibility_spawnattrs_setdisclaim` is private libsystem API,
/// so it is looked up at run time; without it the child runs through
/// `Process` as before.
package enum DisclaimedSpawn {
    package struct Result: Equatable, Sendable {
        /// The exit code, or the signal number for a child killed by one, as
        /// `Process.terminationStatus` reports them.
        package var status: Int32
        /// Whether the child ran with responsibility disclaimed.
        package var disclaimed: Bool
    }

    /// - Parameters:
    ///   - standardOutput: a file the child's stdout truncates and writes,
    ///     or nil to inherit ours.
    ///   - discardStandardError: sends stderr to /dev/null instead of ours.
    package static func run(
        _ executable: String,
        arguments: [String],
        standardOutput: String? = nil,
        discardStandardError: Bool = false
    ) throws -> Result {
        #if canImport(Darwin)
        if let setDisclaim = disclaimFunction {
            let status = try spawn(
                executable, arguments: arguments, standardOutput: standardOutput,
                discardStandardError: discardStandardError, setDisclaim: setDisclaim
            )
            return Result(status: status, disclaimed: true)
        }
        #endif
        let status = try runWithProcess(
            executable, arguments: arguments, standardOutput: standardOutput,
            discardStandardError: discardStandardError
        )
        return Result(status: status, disclaimed: false)
    }

    private static func runWithProcess(
        _ executable: String,
        arguments: [String],
        standardOutput: String?,
        discardStandardError: Bool
    ) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        var handle: FileHandle?
        if let standardOutput {
            _ = FileManager.default.createFile(atPath: standardOutput, contents: nil)
            let opened = try FileHandle(forWritingTo: URL(fileURLWithPath: standardOutput))
            process.standardOutput = opened
            handle = opened
        }
        defer { try? handle?.close() }
        if discardStandardError {
            process.standardError = FileHandle.nullDevice
        }
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    #if canImport(Darwin)
    private typealias SetDisclaim =
        @convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>, Int32) -> Int32

    private static let disclaimFunction: SetDisclaim? = {
        guard let libsystem = dlopen("/usr/lib/libSystem.B.dylib", RTLD_NOW),
            let symbol = dlsym(libsystem, "responsibility_spawnattrs_setdisclaim")
        else { return nil }
        return unsafeBitCast(symbol, to: SetDisclaim.self)
    }()

    private static func spawn(
        _ executable: String,
        arguments: [String],
        standardOutput: String?,
        discardStandardError: Bool,
        setDisclaim: SetDisclaim
    ) throws -> Int32 {
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }

        // CLOEXEC_DEFAULT closes every descriptor without a file action, so
        // stdio the child shares with us is inherited explicitly.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))
        let disclaimed = setDisclaim(&attributes, 1)
        guard disclaimed == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: disclaimed) ?? .EINVAL)
        }
        posix_spawn_file_actions_addinherit_np(&actions, 0)
        if let standardOutput {
            posix_spawn_file_actions_addopen(
                &actions, 1, standardOutput, O_WRONLY | O_CREAT | O_TRUNC, 0o600
            )
        } else {
            posix_spawn_file_actions_addinherit_np(&actions, 1)
        }
        if discardStandardError {
            posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
        } else {
            posix_spawn_file_actions_addinherit_np(&actions, 2)
        }

        var argv = ([executable] + arguments).map { strdup($0) } + [nil]
        let environment = ProcessInfo.processInfo.environment
        var envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { (argv + envp).forEach { free($0) } }

        var pid: pid_t = 0
        let spawned = posix_spawn(&pid, executable, &actions, &attributes, &argv, &envp)
        guard spawned == 0 else { throw POSIXError(POSIXErrorCode(rawValue: spawned) ?? .EINVAL) }

        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1 {
            guard errno == EINTR else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ECHILD) }
        }
        let signal = status & 0x7F
        return signal == 0 ? (status >> 8) & 0xFF : signal
    }
    #endif
}
