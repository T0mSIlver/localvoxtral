import ClaudeContextWire
import Foundation
import Synchronization

// Going to a joined session by voice (#723): "go to payments" brings that
// session's pane to the front, and "call this session payments" gives the
// session dictated into that name. Nothing is typed and no Return is
// pressed. The pieces here are pure: the command parse, a session's names,
// the name lookup and which route can focus a session's pane. The Apple
// events live in the app (`TerminalSessionPaneFocuser`).

/// A spoken session command (#723): the whole dictation, or in Live
/// Auto-Paste a whole segment.
package enum SessionVoiceCommand: Equatable, Sendable {
    /// "go to <name>": bring that session's pane forward (step 1).
    case goTo(String)
    /// "call this session <name>": nickname the session dictated into
    /// (step 2).
    case nameThisSession(String)
}

package enum SessionVoiceCommandParser {
    /// A longer tail is a sentence that happens to start with the opening,
    /// not a session name.
    package static let maxNameWords = 4

    private static let edgePunctuation = CharacterSet(charactersIn: ".,;:!?…\"'")

    /// Not "call this one": "call this one fetchUser" is a coding prompt.
    private enum Kind: Sendable {
        case goTo, nameThisSession
    }

    private static let openings: [(words: [String], kind: Kind)] = [
        (["go", "to"], .goTo),
        (["goto"], .goTo),
        (["call", "this", "session"], .nameThisSession),
        (["name", "this", "session"], .nameThisSession),
    ]

    /// The command when the WHOLE text is an opening plus one to
    /// `maxNameWords` name words, else nil. Case and edge punctuation do not
    /// count.
    package static func command(in text: String) -> SessionVoiceCommand? {
        let words = text
            .split(whereSeparator: \.isWhitespace)
            .map { String($0).trimmingCharacters(in: edgePunctuation) }
            .filter { !$0.isEmpty }
        let folded = words.map(\.caseFoldedForMatching)
        for opening in openings where folded.starts(with: opening.words) {
            let nameWords = words.dropFirst(opening.words.count)
            guard !nameWords.isEmpty, nameWords.count <= maxNameWords else { return nil }
            let name = nameWords.joined(separator: " ")
            guard !SessionNameMatching.key(name).isEmpty else { return nil }
            switch opening.kind {
            case .goTo: return .goTo(name)
            case .nameThisSession: return .nameThisSession(name)
            }
        }
        return nil
    }

    /// The spoken name when the whole text is "go to <name>" (or "goto
    /// <name>").
    package static func spokenName(in text: String) -> String? {
        guard case .goTo(let name)? = command(in: text) else { return nil }
        return name
    }

    /// What a Live Auto-Paste segment heard so far can still become (#747).
    package enum SegmentPrefix: Equatable, Sendable {
        /// "g", "Go", "go t", "call this": it may yet open a command.
        case undecided
        /// It opens a command and has no more name words than a command
        /// takes: only its final can say.
        case possibleCommand
        /// No command can come of it.
        case ordinary
    }

    /// Case and edge punctuation do not count, as in `command(in:)`.
    package static func segmentPrefix(_ text: String) -> SegmentPrefix {
        let words = text
            .split(whereSeparator: \.isWhitespace)
            .map { String($0).trimmingCharacters(in: edgePunctuation).caseFoldedForMatching }
            .filter { !$0.isEmpty }
        let endsInSpace = text.last?.isWhitespace == true
        var heard = words.joined(separator: " ")
        if endsInSpace, !heard.isEmpty { heard += " " }
        let spokenOpenings = openings.map { $0.words.joined(separator: " ") + " " }
        if spokenOpenings.contains(where: { $0.hasPrefix(heard) }) { return .undecided }
        guard let opening = openings.first(where: { words.starts(with: $0.words) && words.count > $0.words.count })
        else { return .ordinary }
        return words.count - opening.words.count > maxNameWords ? .ordinary : .possibleCommand
    }
}

package enum SessionNameMatching {
    /// Letters and digits only, case-folded: "local voxtral", "Localvoxtral"
    /// and `localvoxtral` are one key, and so are "payments api" and
    /// `payments-api`.
    package static func key(_ name: String) -> String {
        String(name.caseFoldedForMatching.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0)
        }.map(Character.init))
    }
}

/// The names a session answers to until it has a nickname (#723 step 2).
package struct SessionDefaultNames: Equatable, Sendable {
    /// The session's git root directory name: the worktree's name in a linked
    /// worktree, the repository's in its main checkout. The cwd's name when
    /// the root is unknown.
    package var primary: String?
    /// The repository's name, when it differs from `primary` (a linked
    /// worktree, or a remote host's project name).
    package var repository: String?

    package init(primary: String?, repository: String?) {
        self.primary = primary
        self.repository = repository
    }

    /// - Parameter repositoryRoot: what a git-root walk from the session's
    ///   cwd found. Ignored for a remote session and when it does not contain
    ///   the cwd.
    package static func of(
        _ snapshot: ClaudeSessionSnapshot,
        repositoryRoot: LearnedTermProjectResolver.RepositoryRoot
    ) -> SessionDefaultNames {
        switch snapshot.workspace {
        case .local(let path)?:
            var directory = path.path
            var mainCheckout = directory
            if case .root(let root, let checkout) = repositoryRoot,
               directory == root || directory.hasPrefix(root + "/")
            {
                directory = root
                mainCheckout = checkout
            }
            let primary = lastComponent(directory)
            let repository = lastComponent(mainCheckout)
            return SessionDefaultNames(
                primary: primary,
                repository: repository == primary ? nil : repository
            )
        case .remoteOpaque(let label)?:
            let project = snapshot.remoteSessionEnvironment?.project
            return SessionDefaultNames(
                primary: label,
                repository: project == label ? nil : project
            )
        case nil:
            return SessionDefaultNames(primary: nil, repository: nil)
        }
    }

    private static func lastComponent(_ path: String) -> String? {
        let name = (path as NSString).lastPathComponent
        return name.isEmpty || name == "/" ? nil : name
    }
}

package struct SessionNameCandidate: Equatable, Sendable {
    package var snapshot: ClaudeSessionSnapshot
    package var names: SessionDefaultNames
    /// What the user called it (#723 step 2), matched ahead of `names`.
    package var nickname: String?

    package init(snapshot: ClaudeSessionSnapshot, names: SessionDefaultNames, nickname: String? = nil) {
        self.snapshot = snapshot
        self.names = names
        self.nickname = nickname
    }
}

package enum SessionNameResolution: Equatable, Sendable {
    case resolved(ClaudeSessionSnapshot)
    /// No live session has that name: the dictation was not a command.
    case unknown
    /// More than one pane answers to that name.
    case ambiguous(count: Int)
}

package enum SessionNameResolver {
    /// A nickname wins over any default name. A match on a git root's name
    /// wins over a match on a repository's name, so "go to cool-roentgen" reaches that worktree even while three
    /// other worktrees of the same repository are open. Sessions on one local
    /// tty are one pane: the most recently active one stands for it.
    package static func resolve(
        spokenName: String,
        candidates: [SessionNameCandidate]
    ) -> SessionNameResolution {
        let spoken = SessionNameMatching.key(spokenName)
        guard !spoken.isEmpty else { return .unknown }
        let panes = onePerPane(candidates)
        let tiers: [(SessionNameCandidate) -> String?] = [\.nickname, \.names.primary, \.names.repository]
        for tier in tiers {
            let matches = panes.filter { candidate in
                guard let name = tier(candidate) else { return false }
                return SessionNameMatching.key(name) == spoken
            }
            switch matches.count {
            case 0: continue
            case 1: return .resolved(matches[0].snapshot)
            default: return .ambiguous(count: matches.count)
            }
        }
        return .unknown
    }

    private static func onePerPane(_ candidates: [SessionNameCandidate]) -> [SessionNameCandidate] {
        var byPane: [String: SessionNameCandidate] = [:]
        var order: [String] = []
        for candidate in candidates {
            let pane = paneKey(candidate.snapshot)
            if let kept = byPane[pane] {
                if candidate.snapshot.lastActivity > kept.snapshot.lastActivity {
                    byPane[pane] = candidate
                }
            } else {
                byPane[pane] = candidate
                order.append(pane)
            }
        }
        return order.compactMap { byPane[$0] }
    }

    private static func paneKey(_ snapshot: ClaudeSessionSnapshot) -> String {
        if snapshot.origin.isLocalAuthenticated, let tty = snapshot.process?.tty {
            return "tty:" + tty
        }
        return "session:" + snapshot.sessionID
    }
}

/// How a session's pane can be brought to the front.
package enum SessionPaneFocusRoute: Equatable, Sendable {
    /// A local session in a plain terminal tab or split, found by its tty.
    /// `termProgram` names the terminal to ask first.
    case terminalTTY(String, termProgram: String?)
    case unsupported(SessionPaneFocusUnsupported)

    package static func of(_ snapshot: ClaudeSessionSnapshot) -> SessionPaneFocusRoute {
        guard snapshot.origin.isLocalAuthenticated else { return .unsupported(.remote) }
        let process = snapshot.process
        // A herdr pane's or cmux surface's tty belongs to the multiplexer, not
        // to a terminal tab, and Desktop hosts its sessions in a web view.
        if process?.desktopSessionID != nil { return .unsupported(.claudeDesktop) }
        if process?.herdrPaneID != nil { return .unsupported(.herdr) }
        if process?.cmuxSurfaceID != nil { return .unsupported(.cmux) }
        guard let tty = process?.tty, !tty.isEmpty else { return .unsupported(.noTTY) }
        return .terminalTTY(tty, termProgram: process?.termProgram)
    }
}

package enum SessionPaneFocusUnsupported: String, Equatable, Sendable {
    case remote
    case claudeDesktop
    case herdr
    case cmux
    case noTTY
}

/// What bringing a session's pane forward came to.
package enum SessionPaneFocusOutcome: Equatable, Sendable {
    /// The terminal selected the pane and, read back the way the join reads
    /// it, its focused pane now carries the session's tty.
    case focused(bundleID: String)
    /// The terminal selected the pane, but the read-back did not show the
    /// session's tty (no answer, or another pane). Never enough for a Return.
    case unverified(bundleID: String)
    /// No running terminal holds the session's tty.
    case paneNotFound
    case unsupported(SessionPaneFocusUnsupported)
}

/// Brings one registry session's pane to the front. The primitive "go to
/// <name>" and #717's answer hotkey share.
@MainActor
package protocol SessionPaneFocusing: AnyObject {
    func focusPane(of session: ClaudeSessionSnapshot) async -> SessionPaneFocusOutcome
}

/// Registry sessions by name, and their panes brought forward.
@MainActor
package final class SessionNavigator {
    /// Names fall back to the cwd's own when the git-root walk has not
    /// answered by then: it `stat`s the session's directories, and one on a
    /// dead mount must not hold the stop commit.
    package static let repositoryRootBound: Duration = .milliseconds(250)

    private let liveSessions: @Sendable () -> [ClaudeSessionSnapshot]
    private let repositoryRoot: @Sendable (String) -> LearnedTermProjectResolver.RepositoryRoot
    private let sleep: @Sendable (Duration) async -> Void
    private let nicknames: SessionNicknameStore?
    package let focuser: any SessionPaneFocusing

    /// - Parameters:
    ///   - repositoryRoot: the git root and main checkout above a local
    ///     directory. Runs off the main actor.
    ///   - sleep: the clock the name bound runs on.
    ///   - nicknames: spoken nicknames; nil, and no session has one.
    package init(
        liveSessions: @escaping @Sendable () -> [ClaudeSessionSnapshot],
        repositoryRoot: @escaping @Sendable (String) -> LearnedTermProjectResolver.RepositoryRoot,
        focuser: any SessionPaneFocusing,
        sleep: @escaping @Sendable (Duration) async -> Void,
        nicknames: SessionNicknameStore? = nil
    ) {
        self.liveSessions = liveSessions
        self.repositoryRoot = repositoryRoot
        self.focuser = focuser
        self.sleep = sleep
        self.nicknames = nicknames
    }

    /// Gives a live session a nickname. False when the session is no longer
    /// live or there is no store.
    package func name(sessionID: String, nickname: String) -> Bool {
        guard let nicknames, liveSessions().contains(where: { $0.sessionID == sessionID }) else {
            return false
        }
        nicknames.setNickname(nickname, for: sessionID)
        return true
    }

    /// Whether any session is live: with none, no dictation can be a go-to,
    /// and Live Auto-Paste holds nothing back.
    package var hasLiveSessions: Bool {
        !liveSessions().isEmpty
    }

    package func resolve(spokenName: String) async -> SessionNameResolution {
        let sessions = liveSessions()
        guard !sessions.isEmpty else { return .unknown }
        var candidates = await Self.candidates(
            for: sessions,
            bound: Self.repositoryRootBound,
            sleep: sleep,
            repositoryRoot: repositoryRoot
        )
        if let nicknames {
            for index in candidates.indices {
                candidates[index].nickname = nicknames.nickname(for: candidates[index].snapshot.sessionID)
            }
        }
        return SessionNameResolver.resolve(spokenName: spokenName, candidates: candidates)
    }

    /// Brings a live session's pane forward by registry id; nil when the
    /// session is no longer live.
    package func focusPane(sessionID: String) async -> SessionPaneFocusOutcome? {
        guard let session = liveSessions().first(where: { $0.sessionID == sessionID }) else {
            return nil
        }
        return await focuser.focusPane(of: session)
    }

    private static func candidates(
        for sessions: [ClaudeSessionSnapshot],
        bound: Duration,
        sleep: @escaping @Sendable (Duration) async -> Void,
        repositoryRoot: @escaping @Sendable (String) -> LearnedTermProjectResolver.RepositoryRoot
    ) async -> [SessionNameCandidate] {
        let lexical = sessions.map {
            SessionNameCandidate(snapshot: $0, names: SessionDefaultNames.of($0, repositoryRoot: .unknown))
        }
        return await withCheckedContinuation { continuation in
            let answer = ResumeOnce(continuation)
            let sleeper = Task.detached {
                await sleep(bound)
                answer.resume(lexical)
            }
            Task.detached {
                let named = sessions.map { session in
                    let root = session.localWorkspacePath.map { repositoryRoot($0.path) } ?? .unknown
                    return SessionNameCandidate(
                        snapshot: session,
                        names: SessionDefaultNames.of(session, repositoryRoot: root)
                    )
                }
                answer.resume(named)
                sleeper.cancel()
            }
        }
    }

    private final class ResumeOnce: Sendable {
        private let continuation: Mutex<CheckedContinuation<[SessionNameCandidate], Never>?>

        init(_ continuation: CheckedContinuation<[SessionNameCandidate], Never>) {
            self.continuation = Mutex(continuation)
        }

        func resume(_ value: [SessionNameCandidate]) {
            continuation.withLock { continuation in
                defer { continuation = nil }
                return continuation
            }?.resume(returning: value)
        }
    }
}

extension SessionNavigator {
    /// The git-root walk the repository pipeline does, and the main checkout
    /// behind a linked worktree. Reads the filesystem.
    package static let liveRepositoryRoot: @Sendable (String) -> LearnedTermProjectResolver.RepositoryRoot = { path in
        RepoIndexing.repositoryRoot(gitRoot: RepoIndexing.findGitRoot(startingAt: path))
    }
}
