import Foundation

/// Where an Overlay Buffer commit landed: the app, the joined session, and
/// how many prompts that session had submitted by the commit.
struct OverlayCommitLanding: Equatable {
    let targetPID: pid_t
    let sessionID: String
    let promptsSubmitted: Int
}

/// A commit inserts its text trimmed, so two dictations into one unsent
/// prompt used to arrive glued: `doing.` + `Usually` read `doing.Usually`
/// (#802). Owner ruling on #802: a commit starts with a space only when the
/// previous commit went to the same app and joined session and that session
/// has submitted no prompt since. Anything less and the caret may sit in a
/// fresh prompt, where a leading space turns `/compact` into text. No
/// trailing space after a commit either.
extension DictationSessionController {
    /// The committer for this commit: the usual one, behind a leading space
    /// when the evidence says the last commit is still in the prompt.
    func overlayCommitter(join: ClaudeSessionJoin?, targetPID: pid_t?) -> any OverlayTextCommitting {
        let committer = overlayTextCommitter
        guard let landing = lastOverlayCommitLanding,
              landing == currentLanding(join: join, targetPID: targetPID)
        else { return committer }
        Log.overlay.info("overlay commit: continues the unsent prompt; leading space")
        return LeadingSpaceOverlayCommitter(base: committer)
    }

    /// The committer for "send that to <name>" in a terminal pane: the same
    /// evidence, judged against the pane's pid and the named session. The
    /// send presses Return, so no later commit continues it (#1480).
    func addressedOverlayCommitter(
        _ committer: any OverlayTextCommitting, session: ClaudeSessionSnapshot, targetPID: pid_t
    ) -> any OverlayTextCommitting {
        let landing = lastOverlayCommitLanding
        lastOverlayCommitLanding = nil
        guard let landing, landing == currentLanding(session: session, targetPID: targetPID) else { return committer }
        Log.overlay.info("send to session: continues the unsent prompt; leading space")
        return LeadingSpaceOverlayCommitter(base: committer)
    }

    /// Remembers where a commit landed, or forgets the last one: a failed
    /// commit, a commit with no join, or one the spoken trigger sent leaves
    /// nothing the next commit may continue. A commit of nothing changed no
    /// prompt, so it changes nothing here either: recording it would arm a
    /// space for a prompt that may be fresh (Vibe review of #806).
    func noteOverlayCommit(
        _ commit: StopCommitCoordinator.CommitResult,
        committedText: String,
        join: ClaudeSessionJoin?,
        targetPID: pid_t?,
        spokenSend: OverlaySpokenSend?
    ) {
        guard commit.outcome != .succeeded || !committedText.trimmed.isEmpty else { return }
        lastOverlayCommitLanding = commit.outcome == .succeeded && spokenSend == nil
            ? currentLanding(join: join, targetPID: targetPID)
            : nil
    }

    /// The join's session as the registry holds it NOW: the join itself was
    /// resolved when the dictation started, and a prompt submitted while it
    /// ran must count (Vibe review of #806). Nil once the session is gone.
    private func currentLanding(join: ClaudeSessionJoin?, targetPID: pid_t?) -> OverlayCommitLanding? {
        guard let join else { return nil }
        return currentLanding(session: join.snapshot, targetPID: targetPID)
    }

    private func currentLanding(session: ClaudeSessionSnapshot, targetPID: pid_t?) -> OverlayCommitLanding? {
        guard let targetPID else { return nil }
        let sessionID = session.sessionID
        let promptsSubmitted: Int
        if let registry = context.claudeSessionJoinResolver?.registry {
            guard let live = registry.snapshot(sessionID: sessionID) else { return nil }
            promptsSubmitted = live.promptsSubmitted
        } else {
            promptsSubmitted = session.promptsSubmitted
        }
        return OverlayCommitLanding(
            targetPID: targetPID, sessionID: sessionID, promptsSubmitted: promptsSubmitted
        )
    }
}

/// Inserts through `base` with one space in front, unless the text already
/// starts with whitespace or with punctuation that attaches to the word
/// before it.
@MainActor
final class LeadingSpaceOverlayCommitter: OverlayTextCommitting {
    private let base: any OverlayTextCommitting

    init(base: any OverlayTextCommitting) {
        self.base = base
    }

    var isAccessibilityTrusted: Bool { base.isAccessibilityTrusted }
    var postsNoKeys: Bool { base.postsNoKeys }

    func insertTextPrioritizingKeyboard(_ text: String, preferredAppPID: pid_t?) -> TextInsertResult {
        base.insertTextPrioritizingKeyboard(Self.spaced(text), preferredAppPID: preferredAppPID)
    }

    func pasteUsingCommandV(_ text: String, preferredAppPID: pid_t?) -> Bool {
        base.pasteUsingCommandV(Self.spaced(text), preferredAppPID: preferredAppPID)
    }

    static func spaced(_ text: String) -> String {
        guard let first = text.first, !first.isWhitespace, !",.;:!?)]}".contains(first) else {
            return text
        }
        return " " + text
    }
}
