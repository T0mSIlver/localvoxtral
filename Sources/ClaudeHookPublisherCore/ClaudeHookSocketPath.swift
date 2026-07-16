import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Where publisher and broker agree to meet.
///
/// Both ends compute this the same way so there is no configuration to keep in
/// sync in the common case, and one env var to override for everything else.
public enum ClaudeHookSocketPath {
    /// Override for non-standard and remote setups. Pointing this at an
    /// SSH-forwarded UNIX socket (`ssh -R`) is the supported remote mode: the
    /// publisher does not care what is on the other end, and the broker still
    /// decides trust from peer credentials — a forwarded peer is `sshd`, not
    /// the app's user session, and lands as `.remote`.
    public static let environmentKey = "LOCALVOXTRAL_CLAUDE_SOCKET"

    /// Relative to the app's Application Support dir on macOS.
    static let socketFileName = "claude-context.sock"
    static let runDirectoryName = "run"

    public static func resolve(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        if let override = environment[environmentKey], !override.isEmpty {
            return override
        }
        return defaultPath(environment: environment)
    }

    static func defaultPath(environment: [String: String]) -> String? {
        guard let home = environment["HOME"], !home.isEmpty else { return nil }
        #if canImport(Darwin)
        return "\(home)/Library/Application Support/localvoxtral/\(runDirectoryName)/\(socketFileName)"
        #else
        // Linux publishers (remote mode) follow XDG. There is no broker on
        // Linux today; this keeps the path predictable for a forwarded socket.
        let base = environment["XDG_RUNTIME_DIR"].flatMap { $0.isEmpty ? nil : $0 }
            ?? "\(home)/.local/state"
        return "\(base)/localvoxtral/\(socketFileName)"
        #endif
    }
}
