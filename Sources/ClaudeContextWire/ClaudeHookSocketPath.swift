import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Where publisher and broker agree to meet.
///
/// Both ends compute this the same way so there is no configuration to keep in
/// sync in the common case, and one environment variable overrides it.
public enum ClaudeHookSocketPath {
    public static let environmentKey = "LOCALVOXTRAL_CLAUDE_SOCKET"

    static let socketFileName = "claude-context.sock"
    static let runDirectoryName = "run"

    public static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
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
        let base = environment["XDG_RUNTIME_DIR"].flatMap { $0.isEmpty ? nil : $0 }
            ?? "\(home)/.local/state"
        return "\(base)/localvoxtral/\(socketFileName)"
        #endif
    }
}
