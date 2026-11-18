import ClaudeContextWire
import Foundation
import Synchronization

// How a joined session is named on screen (#1013): the cue's banner and
// popover line, and the overlay's join badge. Pure: no app, no Apple events.

package enum SessionNameMatching {
    /// The words of `text`, each a `key`: "Fix: the overlay's list" is
    /// ["fix", "the", "overlays", "list"].
    package static func words(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map { key(String($0)) }.filter { !$0.isEmpty }
    }

    /// Letters and digits only, case-folded: "local voxtral", "Localvoxtral"
    /// and `localvoxtral` are one key, and so are "payments api" and
    /// `payments-api`.
    package static func key(_ name: String) -> String {
        String(name.caseFoldedForMatching.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0)
        }.map(Character.init))
    }
}

/// The names a session is shown as (#1013).
package struct SessionDefaultNames: Equatable, Sendable {
    /// The session's git root directory name: the worktree's name in a linked
    /// worktree, the repository's in its main checkout. The cwd's name when
    /// the root is unknown.
    package var primary: String?
    /// The repository's name, when it differs from `primary` (a linked
    /// worktree, or a remote host's project name).
    package var repository: String?
    /// The harness's own title for the session: Claude Desktop's
    /// (`ClaudeDesktopSessionTitles`), else the one its hooks reported
    /// (`ClaudeSessionSnapshot.harnessTitle`, #1020).
    package var title: String?
    /// The branch checked out at the git root, or the one a remote host
    /// reported.
    package var branch: String?

    package init(primary: String?, repository: String?, title: String? = nil, branch: String? = nil) {
        self.primary = primary
        self.repository = repository
        self.title = title
        self.branch = branch
    }

    /// - Parameters:
    ///   - repositoryRoot: what a git-root walk from the session's cwd found.
    ///     Ignored for a remote session and when it does not contain the cwd.
    ///   - title: Claude Desktop's title; nil falls back to the hooks' one.
    ///   - branch: the local git root's branch. A remote session's comes from
    ///     its host.
    package static func of(
        _ snapshot: ClaudeSessionSnapshot,
        repositoryRoot: LearnedTermProjectResolver.RepositoryRoot,
        title: String? = nil,
        branch: String? = nil
    ) -> SessionDefaultNames {
        let title = title ?? snapshot.harnessTitle.flatMap {
            SessionTitleText.clean($0, maxLength: ClaudeDesktopSessionTitles.maxLength)
        }
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
                repository: repository == primary ? nil : repository,
                title: title,
                branch: branch
            )
        case .remoteOpaque(let label)?:
            let project = snapshot.remoteProject
            return SessionDefaultNames(
                primary: label,
                repository: project == label ? nil : project,
                title: title,
                branch: snapshot.remoteBranch
            )
        case nil:
            return SessionDefaultNames(primary: nil, repository: nil, title: title)
        }
    }

    /// `primary` without the random suffix a worktree gets when Claude
    /// creates it: `zealous-chaplygin-aa1a02` reads "zealous-chaplygin".
    /// The suffix is six hex digits, at least one a digit, after at least
    /// two words, so `release-202609` stays whole.
    package var readablePrimary: String? {
        guard let primary else { return nil }
        if Self.isRemoteControlWorktree(primary) { return nil }
        let parts = primary.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count >= 3, let suffix = parts.last, suffix.count == 6,
              suffix.allSatisfy({ $0.isHexDigit && ($0.isNumber || $0.isLowercase) }),
              suffix.contains(where: \.isNumber)
        else { return primary }
        let rest = parts.dropLast().joined(separator: "-")
        return SessionNameMatching.key(rest).isEmpty ? primary : rest
    }

    /// The branch when a person named it: its last component, unless that is
    /// a trunk or the worktree folder the branch was named after
    /// (`t/zealous-chaplygin-aa1a02`).
    package var namedBranch: String? {
        guard let branch, !branch.isEmpty else { return nil }
        var leaf = String(branch.split(separator: "/").last ?? Substring(branch))
        if !leaf.contains(where: \.isLetter) { leaf = branch }
        let key = SessionNameMatching.key(leaf)
        guard !key.isEmpty, !Self.trunks.contains(key) else { return nil }
        let folders = [primary, readablePrimary, repository].compactMap { $0.map(SessionNameMatching.key) }
        if folders.contains(key) { return nil }
        // Claude Code names a worktree's branch `worktree-<folder>`.
        if let primary, key == SessionNameMatching.key("worktree-" + primary) { return nil }
        return leaf
    }

    /// A worktree the Remote Control server made for one session: the folder
    /// is `bridge-` plus the session's id (`bridge-cse_01APpLRSYFaxzhAjYcBXt2ds`),
    /// which no one can say or recognize.
    package static func isRemoteControlWorktree(_ folder: String) -> Bool {
        folder.wholeMatch(of: /bridge-(cse|session)_[A-Za-z0-9]{8,}/) != nil
    }

    private static let trunks: Set<String> = ["main", "master", "trunk", "develop", "development", "head"]

    /// The name without a title: a linked worktree's named
    /// branch, else its folder without the random suffix, else (a Remote
    /// Control worktree) its repository; a main checkout's folder.
    package var fallback: String? {
        if repository != nil, let namedBranch { return namedBranch }
        return readablePrimary ?? repository ?? primary
    }

    /// What the session is shown as before duplicates are told apart.
    package var shown: String? {
        title ?? fallback
    }

    private static func lastComponent(_ path: String) -> String? {
        let name = (path as NSString).lastPathComponent
        return name.isEmpty || name == "/" ? nil : name
    }
}

package struct SessionNameCandidate: Equatable, Sendable {
    package var snapshot: ClaudeSessionSnapshot
    package var names: SessionDefaultNames

    package init(snapshot: ClaudeSessionSnapshot, names: SessionDefaultNames) {
        self.snapshot = snapshot
        self.names = names
    }
}

extension SessionNameCandidate {
    /// The names `AgentAttentionText.name` builds: the cwd's, no git-root walk.
    var withoutWalk: SessionNameCandidate {
        var candidate = self
        candidate.names = SessionDefaultNames.of(snapshot, repositoryRoot: .unknown, title: names.title)
        return candidate
    }
}

package enum SessionNameResolver {
    package static func onePerPane(_ candidates: [SessionNameCandidate]) -> [SessionNameCandidate] {
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

    package static func paneKey(_ snapshot: ClaudeSessionSnapshot) -> String {
        if snapshot.origin.isLocalAuthenticated, let tty = snapshot.process?.tty {
            return "tty:" + tty
        }
        return "session:" + snapshot.sessionID
    }
}

/// What each live session is called on screen (#1013): the overlay's
/// destinations, the popover's "… needs you", banners.
package enum SessionShownNames {
    package static let separator = " · "

    /// Session id to name: its harness's title, else its
    /// folder or branch (`SessionDefaultNames.fallback`), with duplicates
    /// told apart. Every session on one pane gets that pane's name.
    package static func of(_ candidates: [SessionNameCandidate]) -> [String: String] {
        let panes = SessionNameResolver.onePerPane(candidates)
        let names = distinct(panes, name: base)
        var byPane: [String: String] = [:]
        for pane in panes {
            byPane[SessionNameResolver.paneKey(pane.snapshot)] = names[pane.snapshot.sessionID]
        }
        var result: [String: String] = [:]
        for candidate in candidates {
            result[candidate.snapshot.sessionID] = byPane[SessionNameResolver.paneKey(candidate.snapshot)]
        }
        return result
    }

    /// A pane's name before duplicates are told apart.
    package static func base(_ candidate: SessionNameCandidate) -> String? {
        candidate.names.shown
    }

    /// Names made unique among `panes`. A name only one pane has stays as
    /// it is. When several share one, each gets its agent's name when no
    /// other pane of the group runs that agent ("localvoxtral · Codex"),
    /// else a number by first seen ("localvoxtral · 1", "localvoxtral · 2").
    package static func distinct(
        _ panes: [SessionNameCandidate],
        name: (SessionNameCandidate) -> String?
    ) -> [String: String] {
        var groups: [String: [(candidate: SessionNameCandidate, name: String)]] = [:]
        for pane in panes {
            guard let base = name(pane), !SessionNameMatching.key(base).isEmpty else { continue }
            groups[SessionNameMatching.key(base), default: []].append((pane, base))
        }
        var result: [String: String] = [:]
        for group in groups.values {
            guard group.count > 1 else {
                result[group[0].candidate.snapshot.sessionID] = group[0].name
                continue
            }
            let ordered = group.sorted { lhs, rhs in
                if lhs.candidate.snapshot.firstSeen != rhs.candidate.snapshot.firstSeen {
                    return lhs.candidate.snapshot.firstSeen < rhs.candidate.snapshot.firstSeen
                }
                return lhs.candidate.snapshot.sessionID < rhs.candidate.snapshot.sessionID
            }
            let agentCounts = Dictionary(grouping: ordered, by: \.candidate.snapshot.agent).mapValues(\.count)
            var ordinal = 0
            for member in ordered {
                let id = member.candidate.snapshot.sessionID
                let agent = member.candidate.snapshot.agent
                let suffix: String
                if agentCounts[agent] == 1 {
                    suffix = AgentAttentionText.agentName(agent)
                } else {
                    ordinal += 1
                    suffix = String(ordinal)
                }
                result[id] = member.name + separator + suffix
            }
        }
        return result
    }
}
