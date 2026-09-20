import ClaudeContextWire
import Foundation

/// Which project a dictation belongs to, so what it teaches is remembered
/// where it applies. A name learned in one repo is wrong in the next one —
/// keying by project is what lets the remembered list keep growing without
/// every project paying for every other project's vocabulary.
///
/// Pure, and deliberately without a filesystem: both inputs are already
/// resolved by the time a commit asks. The repository root comes from the
/// vocabulary pipeline, which resolves it off the main actor under a deadline
/// (`RepoVocabularyService.entries`); walking for a `.git` directory again on
/// the commit path would put an unbounded `stat` on a possibly unresponsive
/// mount in front of the user's text (review, 2026-09-20).
enum LearnedTermProjectResolver {
    /// A project's stable key and the name a human would recognize.
    ///
    /// The key is a local directory, `remote:<label>` for a session whose
    /// files are on another machine, or `shared` for a dictation with no
    /// project at all. Those three shapes cannot collide: a local key always
    /// starts with `/`, and a remote label is stripped to alphanumerics, `-`,
    /// `_` and `.` before it gets here (`ClaudeWorkspaceReference.opaqueLabel`).
    struct Identity: Equatable, Sendable {
        let key: String
        let name: String
    }

    /// Where a dictation that belongs to no project remembers what it learned.
    /// Not a fallback for a project we failed to resolve — from the app's side
    /// those are the same thing, and keeping one bucket for both is what lets
    /// dictation outside a repo (a browser, a note) learn at all.
    static let shared = Identity(key: "shared", name: "No project")

    static let remoteKeyPrefix = "remote:"

    /// - Parameters:
    ///   - repositoryRoot: the git root the vocabulary pipeline resolved for
    ///     the focused terminal, or nil when it did not run or found none.
    ///   - workspace: the joined coding-agent session's workspace, if any.
    ///
    /// The joined session decides, because it names the tree the speaker is
    /// talking about, and the repository root is what widens it: a session
    /// running in a subdirectory teaches the repo, not the subdirectory, so
    /// every session in one checkout shares one vocabulary. A root that does
    /// NOT contain the session's directory describes a different tab and is
    /// ignored rather than merged.
    static func resolve(
        repositoryRoot: String?,
        workspace: ClaudeWorkspaceReference?
    ) -> Identity {
        switch workspace {
        case .local(let path):
            let directory = normalize(path.path)
            if let root = repositoryRoot.map(normalize), contains(root: root, directory: directory) {
                return identity(forDirectory: root)
            }
            return identity(forDirectory: directory)
        case .remoteOpaque(let label):
            // The session's files are on another machine; the local terminal's
            // repo says nothing about them. The label IS the identity — two
            // remote checkouts with the same directory name share one bucket,
            // which is the price of never holding a remote path.
            return Identity(key: remoteKeyPrefix + label, name: label)
        case .none:
            guard let repositoryRoot else { return shared }
            return identity(forDirectory: normalize(repositoryRoot))
        }
    }

    private static func identity(forDirectory directory: String) -> Identity {
        let name = (directory as NSString).lastPathComponent
        return Identity(key: directory, name: name.isEmpty ? directory : name)
    }

    /// Prefix comparison on normalized paths, so `/a/bc` is not a child of
    /// `/a/b` and a directory is its own root.
    private static func contains(root: String, directory: String) -> Bool {
        directory == root || directory.hasPrefix(root + "/")
    }

    /// Collapses duplicate and trailing separators and resolves `.`/`..`, so
    /// the two inputs are comparable and one directory has one key.
    private static func normalize(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }
}
