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
    /// The mod that takes this commit, or nil: a commit that sends no
    /// Return of its own fills through the session's mod. A spoken send by
    /// Return keeps the keyboard, since a fill handed off to the mod could
    /// arrive behind the key; one the mod submits asks the mod to submit
    /// after its fill (#1644).
    func overlayCommitMod(
        join: ClaudeSessionJoin?, targetPID: pid_t?, spokenSend: OverlaySpokenSend?
    ) -> ModChannelOverlayCommitter? {
        switch spokenSend {
        case nil: modChannelCommitter(join: join, targetPID: targetPID)
        case .modSubmit: modChannelCommitter(join: join, targetPID: targetPID, submits: true)
        case .returnKey, .promptRelaySubmit: nil
        }
    }

    /// Where this commit goes: `mod` when one takes it, the usual route
    /// otherwise, behind a leading space when `draft` (the session's prompt
    /// box at the stop) ends in a word, or, without one, when the evidence
    /// says the last commit is still in the prompt.
    func overlayCommitDestination(
        join: ClaudeSessionJoin?,
        targetPID: pid_t?,
        mod: ModChannelOverlayCommitter?,
        draft: ClaudePromptDraft? = nil
    ) -> OverlayCommitDestination {
        var destination: OverlayCommitDestination = if let mod {
            .route { mod.handOff($0, preferredAppPID: $1) }
        } else {
            overlayTextDestination
        }
        if let join, let draft, draft.decidesLeadingSpace(for: join) {
            guard draft.commitNeedsLeadingSpace else {
                Log.overlay.info("overlay commit: the prompt box is empty or ends in whitespace; no leading space")
                return destination
            }
            Log.overlay.info("overlay commit: the prompt box ends in a word; leading space")
            destination.leadingSpace = true
            return destination
        }
        guard let landing = lastOverlayCommitLanding,
              landing.isAt(currentLanding(join: join, targetPID: targetPID))
        else { return destination }
        Log.overlay.info("overlay commit: continues the unsent prompt; leading space")
        destination.leadingSpace = true
        return destination
    }

    /// Whether "send that to <name>" in a terminal pane starts with a
    /// space: the same evidence, judged against the pane's pid and the
    /// named session (#1480).
    func addressedCommitNeedsLeadingSpace(session: ClaudeSessionSnapshot, targetPID: pid_t) -> Bool {
        guard let landing = lastOverlayCommitLanding,
              landing.isAt(currentLanding(session: session, targetPID: targetPID))
        else { return false }
        Log.overlay.info("send to session: continues the unsent prompt; leading space")
        return true
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
    /// space for a prompt that may be fresh (Vibe review of #806). A lone
    /// send phrase commits nothing either: its submit forgets the landing
    /// once it happened (`sendOverlaySpokenSendIfNeeded`, the mod's answer),
    /// since a refused or blocked one leaves the box as it was (#1870).
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
