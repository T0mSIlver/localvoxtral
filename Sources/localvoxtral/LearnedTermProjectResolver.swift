import ClaudeContextWire
import Foundation

/// Which project a dictation belongs to, so what it teaches is remembered
/// where it applies. A name learned in one repo is wrong in the next one —
/// keying by project is what lets the remembered list keep growing without
/// every project paying for every other project's vocabulary.
///
/// Pure, and deliberately without a filesystem — not one `stat`, which is why
/// even the path tidying below is lexical. The repository root comes from the
/// vocabulary pipeline, which resolves it off the main actor under a deadline
/// (`RepoVocabularyService.entries`); walking for a `.git` directory again on
/// the commit path would put an unbounded `stat` on a possibly unresponsive
/// mount in front of the user's text (review, 2026-09-20).
///
/// Known limit, accepted: two spellings of one checkout — through a symlink,
/// or differing only in case on a case-insensitive volume — are two projects.
/// Resolving that needs the filesystem, which is the one thing this must not
/// touch; the cost is a split bucket that both halves fill, not a wrong
/// correction.
enum LearnedTermProjectResolver {
    /// A project's stable key and the name a human would recognize.
    ///
    /// The key is a local directory, `remote:<label>` for a session whose
    /// files are on another machine, or `shared` for a dictation with no
    /// project at all. Those three shapes cannot collide: a local key always
    /// starts with `/`, and a remote label is stripped to alphanumerics, `-`,
    /// `_` and `.` before it gets here (`ClaudeWorkspaceReference.opaqueLabel`).
    typealias Identity = LearnedTermProjectIdentity

    /// Where a dictation that belongs to no project remembers what it learned.
    /// Not a fallback for a project we failed to resolve — from the app's side
    /// those are the same thing, and keeping one bucket for both is what lets
    /// dictation outside a repo (a browser, a note) learn at all.
    static let shared = Identity(key: "shared", name: "No project")

    static let remoteKeyPrefix = "remote:"

    /// What the vocabulary pipeline was able to say about this dictation's
    /// repository. The distinction between "there is no repo here" and "no one
    /// looked" is the whole point: only the first is a project of its own, and
    /// treating the second as one files a repo's terms in the bucket that
    /// grounds every project-less dictation (review, 2026-09-20).
    enum RepositoryRoot: Equatable, Sendable {
        /// The pipeline did not run, or was abandoned before it resolved:
        /// the setting is off, the endpoint is not permitted, a previous
        /// pipeline still holds the single-flight gate, or the deadline
        /// expired first.
        case unknown
        /// It ran, and the focused terminal is not in a repository.
        case noRepository
        case root(String)
    }

    /// - Parameters:
    ///   - repositoryRoot: what the vocabulary pipeline established about the
    ///     focused terminal's repository.
    ///   - workspace: the joined coding-agent session's workspace, if any.
    ///
    /// Returns nil when the project is simply not known — nothing is learned
    /// and nothing is read for that dictation. That is deliberately not the
    /// same as `shared`: a dictation with no project teaches the shared
    /// bucket, while a dictation whose project we failed to establish teaches
    /// nothing, because the alternative is filing one repo's spellings where
    /// every project-less dictation will read them.
    ///
    /// The joined session decides when there is one, because it names the tree
    /// the speaker is talking about and it is stable whatever the pipeline
    /// did. The repository root is what widens it: a session running in a
    /// subdirectory teaches the repo, not the subdirectory, so every session
    /// in one checkout shares one vocabulary. A root that does NOT contain the
    /// session's directory describes a different tab and is ignored.
    static func resolve(
        repositoryRoot: RepositoryRoot,
        workspace: ClaudeWorkspaceReference?
    ) -> Identity? {
        switch workspace {
        case .local(let path):
            let directory = normalize(path.path)
            if case .root(let root) = repositoryRoot {
                let normalizedRoot = normalize(root)
                if contains(root: normalizedRoot, directory: directory) {
                    return identity(forDirectory: normalizedRoot)
                }
            }
            return identity(forDirectory: directory)
        case .remoteOpaque(let label):
            // The session's files are on another machine; the local terminal's
            // repo says nothing about them. The label IS the identity — two
            // remote checkouts with the same directory name share one bucket,
            // which is the price of never holding a remote path.
            return Identity(key: remoteKeyPrefix + label, name: label)
        case .none:
            switch repositoryRoot {
            case .root(let root): return identity(forDirectory: normalize(root))
            case .noRepository: return shared
            case .unknown: return nil
            }
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

    /// Collapses duplicate and trailing separators and resolves `.`/`..`
    /// lexically, so the two inputs are comparable and one directory has one
    /// key. `URL.standardizedFileURL` would do the same and more, at the cost
    /// of `stat`ing the path — which on the commit path is exactly the syscall
    /// this type exists to avoid.
    private static func normalize(_ path: String) -> String {
        var components: [Substring] = []
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch component {
            case ".": continue
            case "..":
                if !components.isEmpty { components.removeLast() }
            default: components.append(component)
            }
        }
        return "/" + components.joined(separator: "/")
    }
}
