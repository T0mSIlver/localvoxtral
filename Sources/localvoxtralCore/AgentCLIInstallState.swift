import Foundation

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

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
    ///
    /// Both re-check what is at the link when they run, because Settings
    /// decided from a state it read earlier (and an administrator prompt can
    /// stay open for minutes): anything but a link to a copy of the app makes
    /// them exit 3 and leaves it alone.
    package static func installCommand(bundledBinary: String, linkPath: String = linkPath) -> String {
        let directory = (linkPath as NSString).deletingLastPathComponent
        return "mkdir -p \(shellQuoted(directory)) && "
            + refuseForeignCommand(bundledBinary: bundledBinary, linkPath: linkPath)
            + " && ln -sfn \(shellQuoted(bundledBinary)) \(shellQuoted(linkPath))"
    }

    package static func removeCommand(bundledBinary: String, linkPath: String = linkPath) -> String {
        refuseForeignCommand(bundledBinary: bundledBinary, linkPath: linkPath)
            + " && rm -f \(shellQuoted(linkPath))"
    }

    /// `read`'s ownership rule in `sh`, on the link's text as written: a
    /// relative link to a copy of the app is refused here, which only costs a
    /// failed Remove.
    private static func refuseForeignCommand(bundledBinary: String, linkPath: String) -> String {
        let link = shellQuoted(linkPath)
        return "if [ -L \(link) ]; then case \"$(readlink \(link))\" in "
            + "\(shellQuoted(bundledBinary))|*/Contents/MacOS/\(binaryName)) ;; *) exit 3 ;; esac; "
            + "elif [ -e \(link) ]; then exit 3; fi"
    }

    package enum MutationError: Error, Equatable {
        /// What is at the link now is not ours.
        case foreignFile
        case failed(errno: Int32)
    }

    /// The direct mutators, for a link directory the user can write. Like the
    /// commands, they re-read the link first and refuse a foreign file.
    package static func removeLink(
        linkPath: String = linkPath,
        bundledBinary: String,
        fileManager: FileManager = .default
    ) throws {
        switch read(linkPath: linkPath, bundledBinary: bundledBinary, fileManager: fileManager) {
        case .notInstalled: return
        case .foreign: throw MutationError.foreignFile
        case .installed, .otherCopy: try unlinkLink(linkPath)
        }
    }

    package static func installLink(
        linkPath: String = linkPath,
        bundledBinary: String,
        fileManager: FileManager = .default
    ) throws {
        switch read(linkPath: linkPath, bundledBinary: bundledBinary, fileManager: fileManager) {
        case .notInstalled: break
        case .foreign: throw MutationError.foreignFile
        case .installed, .otherCopy: try unlinkLink(linkPath)
        }
        try fileManager.createSymbolicLink(atPath: linkPath, withDestinationPath: bundledBinary)
    }

    /// `unlink`, not `removeItem`: it never recurses into a directory that
    /// took the link's place.
    private static func unlinkLink(_ path: String) throws {
        guard unlink(path) == 0 else { throw MutationError.failed(errno: errno) }
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
