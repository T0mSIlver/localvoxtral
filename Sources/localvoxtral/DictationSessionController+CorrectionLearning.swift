import Foundation

/// Hands a committed dictation to `CorrectionLearning`, which compares it with
/// the next prompt the joined session submits.
extension DictationSessionController {
    /// Only a dictation with a join can be compared: the join names the
    /// session whose submitted prompt holds the user's fix, and without one
    /// no prompt belongs to this text.
    ///
    /// - Parameter project: the project the polish pipeline resolved, which
    ///   widens a session in a subdirectory to its repository. Without
    ///   polish, the joined session's own workspace decides.
    func expectCorrection(
        of inserted: @autoclosure () -> String,
        join: ClaudeSessionJoin?,
        project: LearnedTermProjectResolver.Identity?
    ) {
        guard let correctionLearning, let join else { return }
        guard let project = project ?? LearnedTermProjectResolver.resolve(
            repositoryRoot: .unknown,
            workspace: join.snapshot.workspace
        ) else { return }
        correctionLearning.expect(
            inserted: inserted(),
            sessionID: join.snapshot.sessionID,
            project: project
        )
    }

    /// What Live Auto-Paste typed. The insertion service records every
    /// released chunk that reached the field, which is exact: the spoken
    /// send cut, the finals typed in place of partials, the newline guard.
    /// A session that typed without the hold-back stream keeps no record;
    /// for it the transcript with the latched rules stands in. Only
    /// the latched dictionary: loading one here would read the config file
    /// on a stop that never loaded it.
    func liveTypedText() -> String {
        if let typed = textInsertion.liveTypedTextThisSession { return typed }
        let raw = transcript.currentDictationEventText
        guard let dictionary = sessionReplacementDictionary else { return raw }
        return LiveReplacementCorrector.completedBoundaryCorrectedText(
            raw,
            dictionary: dictionary,
            includeFinalUnboundedWord: true
        )
    }

    /// A Live dictation is compared only when all of it reached the field
    /// and the user, not the spoken send trigger, decides when it is sent:
    /// text the trigger already submitted was sent unedited, and text still
    /// pending never reached the prompt at all.
    var liveDictationCanTeachACorrection: Bool {
        !textInsertion.hasPendingInsertionText && !liveSpokenSendReturnPressed
    }
}
