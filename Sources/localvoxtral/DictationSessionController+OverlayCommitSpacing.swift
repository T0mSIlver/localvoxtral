import Foundation

/// Where an Overlay Buffer commit landed: the app, the joined session, and
/// how many prompts that session had submitted by the commit.
struct OverlayCommitLanding: Equatable {
    let targetPID: pid_t
    let sessionID: String
    let promptsSubmitted: Int
    /// The start generation of the dictation that committed. Not part of
    /// where it landed: it names whose refusal may forget it.
    var generation: UInt64 = 0

    func isAt(_ other: OverlayCommitLanding?) -> Bool {
        guard let other else { return false }
        return targetPID == other.targetPID && sessionID == other.sessionID
            && promptsSubmitted == other.promptsSubmitted
    }
}

/// A commit inserts its text trimmed, so two dictations into one unsent
/// prompt used to arrive glued: `doing.` + `Usually` read `doing.Usually`
/// (#802). Owner ruling on #802: a commit starts with a space only when the
/// previous commit went to the same app and joined session and that session
/// has submitted no prompt since. Anything less and the caret may sit in a
/// fresh prompt, where a leading space turns `/compact` into text. No
/// trailing space after a commit either.
///
/// Where the joined session's mod read its prompt box at the stop, the box
/// decides instead of that guess (#1406): a space only when the cursor
/// follows a character that is not whitespace.
extension DictationSessionController {
    /// The committer for this commit: the usual one, or the session's mod
    /// when the commit sends no Return of its own, behind a leading space
    /// when `draft` (the session's prompt box at the stop) ends in a word,
    /// or, without one, when the evidence says the last commit is still in
    /// the prompt.
    ///
    /// A spoken send by Return keeps the keyboard, since a fill handed off
    /// to the mod could arrive behind the key; one the mod submits asks the
    /// mod to submit after its fill (#1644).
    func overlayCommitter(
        join: ClaudeSessionJoin?,
        targetPID: pid_t?,
        spokenSend: OverlaySpokenSend?,
        draft: ClaudePromptDraft? = nil
    ) -> any OverlayTextCommitting {
        let modCommitter: ModChannelOverlayCommitter? = switch spokenSend {
        case nil: modChannelCommitter(join: join, targetPID: targetPID)
        case .modSubmit: modChannelCommitter(join: join, targetPID: targetPID, submits: true)
        case .returnKey, .promptRelaySubmit: nil
        }
        let committer: any OverlayTextCommitting = modCommitter ?? overlayTextCommitter
        if let join, let draft, draft.decidesLeadingSpace(for: join) {
            guard draft.commitNeedsLeadingSpace else {
                Log.overlay.info("overlay commit: the prompt box is empty or ends in whitespace; no leading space")
                return committer
            }
            Log.overlay.info("overlay commit: the prompt box ends in a word; leading space")
            return LeadingSpaceOverlayCommitter(base: committer)
        }
        guard let landing = lastOverlayCommitLanding,
              landing.isAt(currentLanding(join: join, targetPID: targetPID))
        else { return committer }
        Log.overlay.info("overlay commit: continues the unsent prompt; leading space")
        return LeadingSpaceOverlayCommitter(base: committer)
    }

    /// The committer for "send that to <name>" in a terminal pane: the same
    /// evidence, judged against the pane's pid and the named session (#1480).
    func addressedOverlayCommitter(
        _ committer: any OverlayTextCommitting, session: ClaudeSessionSnapshot, targetPID: pid_t
    ) -> any OverlayTextCommitting {
        guard let landing = lastOverlayCommitLanding,
              landing.isAt(currentLanding(session: session, targetPID: targetPID))
        else { return committer }
        Log.overlay.info("send to session: continues the unsent prompt; leading space")
        return LeadingSpaceOverlayCommitter(base: committer)
    }

    /// Whether the last commit went into `session`'s unsent prompt and the
    /// session has submitted nothing since, whichever app shows it: a mod's
    /// fill lands in the session's own box, wherever its pane is.
    func lastCommitContinuesPrompt(of session: ClaudeSessionSnapshot) -> Bool {
        guard let landing = lastOverlayCommitLanding, landing.sessionID == session.sessionID else { return false }
        let current = currentLanding(session: session, targetPID: landing.targetPID)
        guard landing.isAt(current) else { return false }
        Log.overlay.info("send to session: continues the unsent prompt; leading space")
        return true
    }

    /// An addressed send that pressed Return, or failed to type, leaves
    /// nothing in the named session's prompt to continue. A landing in
    /// another session is that prompt's evidence and stays, as does one
    /// whose text was typed but not submitted.
    func forgetOverlayCommitLanding(inSession sessionID: String) {
        guard lastOverlayCommitLanding?.sessionID == sessionID else { return }
        lastOverlayCommitLanding = nil
    }

    /// The same, for a send that answers late: a landing a later dictation
    /// recorded while it waited is that dictation's evidence and stays.
    func forgetOverlayCommitLanding(inSession sessionID: String, committedBy generation: UInt64) {
        guard let landing = lastOverlayCommitLanding, landing.generation <= generation else { return }
        forgetOverlayCommitLanding(inSession: sessionID)
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
        // The committer read the generation just now, with no await between.
        lastOverlayCommitLanding = commit.outcome == .succeeded && spokenSend == nil
            ? currentLanding(join: join, targetPID: targetPID, generation: sessionStartGeneration)
            : nil
    }

    /// The join's session as the registry holds it NOW: the join itself was
    /// resolved when the dictation started, and a prompt submitted while it
    /// ran must count (Vibe review of #806). Nil once the session is gone.
    private func currentLanding(
        join: ClaudeSessionJoin?, targetPID: pid_t?, generation: UInt64 = 0
    ) -> OverlayCommitLanding? {
        guard let join else { return nil }
        return currentLanding(session: join.snapshot, targetPID: targetPID, generation: generation)
    }

    private func currentLanding(
        session: ClaudeSessionSnapshot, targetPID: pid_t?, generation: UInt64 = 0
    ) -> OverlayCommitLanding? {
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
            targetPID: targetPID, sessionID: sessionID, promptsSubmitted: promptsSubmitted, generation: generation
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
