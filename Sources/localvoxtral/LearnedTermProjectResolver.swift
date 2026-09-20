import ClaudeContextWire
import Foundation

/// Which project a dictation belongs to, so what it teaches is remembered
/// where it applies. A name learned in one repo is wrong in the next one —
/// keying by project is what lets the remembered list keep growing without
/// every project paying for every other project's vocabulary.
///
/// Pure except for the directory checks, which are injected. The window title
/// is read by the caller, on the main actor, at the same moment it samples the
/// screen — never here.
enum LearnedTermProjectResolver {
    /// A project's stable key and the name a human would recognize.
    ///
    /// The key is a local git root, `remote:<label>` for a session whose files
    /// are on another machine, or `shared` for a dictation with no project at
    /// all. Those three shapes cannot collide: a local key always starts with
    /// `/`, and a remote label is stripped to alphanumerics, `-`, `_` and `.`
    /// before it gets here (`ClaudeWorkspaceReference.opaqueLabel`).
    struct Identity: Equatable, Sendable {
        let key: String
        let name: String
    }

    /// Where a dictation that belongs to no project remembers what it learned.
    /// Not a fallback for a project we failed to resolve — those are the same
    /// thing from the app's side, and keeping one bucket for both is what lets
    /// dictation outside a repo (a browser, a note) learn at all.
    static let shared = Identity(key: "shared", name: "No project")

    static let remoteKeyPrefix = "remote:"

    /// The joined session's workspace decides, because it is the one signal
    /// that names the tree the speaker is actually talking about. The
    /// terminal's own working directory is the fallback for an unjoined
    /// dictation, and it is a fallback rather than a peer: a terminal window
    /// title describes the focused tab, which a background agent's session
    /// does not have to match.
    static func resolve(
        workspace: ClaudeWorkspaceReference?,
        windowTitle: String?,
        fileManager: FileManager = .default
    ) -> Identity {
        if let workspace {
            switch workspace {
            case .local(let path):
                return localIdentity(forDirectory: path.path, fileManager: fileManager)
            case .remoteOpaque(let label):
                // No path to walk on this machine, so the label IS the
                // identity. Two remote checkouts with the same directory name
                // share one bucket; that is the price of never holding a
                // remote path, and it is the right trade for a label.
                return Identity(key: remoteKeyPrefix + label, name: label)
            }
        }
        if let windowTitle,
           let directory = TerminalWorkingDirectoryResolver.resolveWorkingDirectory(
               fromWindowTitle: windowTitle,
               isDirectory: { path in
                   var isDirectory: ObjCBool = false
                   return fileManager.fileExists(atPath: path, isDirectory: &isDirectory)
                       && isDirectory.boolValue
               }
           )
        {
            return localIdentity(forDirectory: directory, fileManager: fileManager)
        }
        return shared
    }

    /// A directory inside a repo is keyed by the repo, so every worktree
    /// subdirectory teaches the same project. A directory outside one has no
    /// project: keying by a bare path would mint a project for every folder
    /// the speaker passes through.
    private static func localIdentity(
        forDirectory directory: String,
        fileManager: FileManager
    ) -> Identity {
        guard let root = RepoIndexing.findGitRoot(startingAt: directory, fileManager: fileManager)
        else { return shared }
        let path = URL(fileURLWithPath: root).standardizedFileURL.path
        let name = (path as NSString).lastPathComponent
        return Identity(key: path, name: name.isEmpty ? path : name)
    }
}
