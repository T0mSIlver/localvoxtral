import Foundation

/// The ssh config file the app uses: `~/.ssh/config`, or
/// `LOCALVOXTRAL_SSH_CONFIG` when set (#1029).
///
/// The override is for the herdr lane on the owner's Mac: its fixture writes
/// its host aliases into a file of its own and hands the app that file, so no
/// run, even one killed halfway, edits the owner's `~/.ssh/config`. When set,
/// every `ssh` the app starts gets `-F <file>` (which also skips
/// `/etc/ssh/ssh_config`), and enrollment writes its host block into that file
/// instead of `~/.ssh/config`. A relative value resolves against the working
/// directory in both places, the way `ssh -F` resolves it.
package enum SSHConfigOverride {
    package static let environmentKey = "LOCALVOXTRAL_SSH_CONFIG"

    /// nil when unset or empty: ssh reads the user's own configuration chain.
    package static func path(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        guard let path = environment[environmentKey], !path.isEmpty else { return nil }
        return path
    }

    /// `argv` with `-F <file>` right after `ssh` when the override is set;
    /// `argv` unchanged otherwise. `argv[0]` is the program name, as every
    /// ssh invocation in the app is built.
    package static func argv(
        _ argv: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String] {
        guard let path = path(environment: environment), let program = argv.first else { return argv }
        return [program, "-F", path] + argv.dropFirst()
    }

    /// The file enrollment reads and rewrites.
    package static func configFileURL(
        homeDirectoryURL: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let path = path(environment: environment) {
            return URL(fileURLWithPath: path, isDirectory: false).standardizedFileURL
        }
        return homeDirectoryURL
            .appendingPathComponent(".ssh", isDirectory: true)
            .appendingPathComponent("config", isDirectory: false)
    }
}
