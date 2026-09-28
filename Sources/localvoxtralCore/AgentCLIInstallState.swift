import Foundation

/// Where Settings puts the `localvoxtral` command (#721), and what is there
/// now. The command is a symbolic link to the binary inside the app bundle,
/// so an app update updates it; the way MacWhisper installs `mw`.
package enum AgentCLIInstallState: Equatable, Sendable {
    case notInstalled
    /// A link to this app's binary.
    case installed
    /// A link to another copy of the app: an old download, a moved bundle.
    case otherCopy
    /// Something we did not put there. Never replaced or removed.
    case foreign

    package static let linkPath = "/usr/local/bin/localvoxtral"
    /// The binary's name in `Contents/MacOS` (`scripts/package_app.sh`).
    package static let binaryName = "localvoxtral-cli"

    /// Reads the link without following it: a dangling link to a deleted copy
    /// of the app is still ours to replace.
    package static func read(
        linkPath: String = linkPath,
        bundledBinary: String,
        fileManager: FileManager = .default
    ) -> AgentCLIInstallState {
        guard let destination = try? fileManager.destinationOfSymbolicLink(atPath: linkPath) else {
            // Not a link: nothing there, or a file of someone else's.
            return (try? fileManager.attributesOfItem(atPath: linkPath)) == nil ? .notInstalled : .foreign
        }
        let resolved = destination.hasPrefix("/")
            ? destination
            : (linkPath as NSString).deletingLastPathComponent + "/" + destination
        let target = URL(fileURLWithPath: resolved).standardizedFileURL.path
        if target == URL(fileURLWithPath: bundledBinary).standardizedFileURL.path { return .installed }
        return target.hasSuffix("/Contents/MacOS/" + binaryName) ? .otherCopy : .foreign
    }

    /// The shell commands that make the link, or remove it. Paths are
    /// single-quoted for `sh`, so a bundle path with spaces or quotes stays
    /// one argument.
    package static func installCommand(bundledBinary: String, linkPath: String = linkPath) -> String {
        let directory = (linkPath as NSString).deletingLastPathComponent
        return "mkdir -p \(shellQuoted(directory)) && ln -sfn \(shellQuoted(bundledBinary)) \(shellQuoted(linkPath))"
    }

    package static func removeCommand(linkPath: String = linkPath) -> String {
        "rm -f \(shellQuoted(linkPath))"
    }

    package static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// `do shell script` with an administrator prompt, as an AppleScript
    /// source line for `osascript -e`.
    package static func privilegedAppleScript(_ command: String) -> String {
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "do shell script \"\(escaped)\" with administrator privileges"
    }
}
