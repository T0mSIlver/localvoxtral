import Foundation

/// Pure decision logic for the Live Auto-Paste post-session dictionary sweep
/// (issue #23, Stage 1).
///
/// Given the session's raw text, the dictionary-processed text, the current
/// field value, and the tracked insertion span, this decides whether the sweep
/// should apply and, if so, exactly which UTF-16 range to replace. It is
/// isolated from all Accessibility I/O so the span-location arithmetic and the
/// content-verification guard can be unit-tested without mocking AX.
///
/// The content-verification guard is the single load-bearing safety property of
/// the feature: the sweep only proceeds when the text currently occupying the
/// tracked span is byte-identical to what we believe we inserted. This prevents
/// the sweep from corrupting user edits, field auto-corrections, or stale span
/// tracking — if anything differs, the decision is `.skip` and the field is left
/// untouched.
enum LiveAutoPasteSweep {
    enum Decision: Equatable {
        /// Replace `[location, location + length)` (UTF-16 / NSString offsets)
        /// in the target field with `replacement`.
        case apply(replacement: String, location: Int, length: Int)
        /// Do not touch the field. `reason` is a short diagnostic for logging.
        case skip(reason: String)
    }

    /// Computes the sweep decision from the session state and the field's
    /// current value.
    ///
    /// - Parameters:
    ///   - rawText: The session's accumulated text as spoken
    ///     (`currentDictationEventText`), i.e. what was live-inserted.
    ///   - processedText: The result of applying the replacement dictionary to
    ///     `rawText`.
    ///   - fieldValue: The full current text of the target field (`kAXValue`).
    ///   - startCaret: The caret location (UTF-16 offset) recorded at session
    ///     start, before any live insertions.
    ///   - insertedUTF16Length: The cumulative UTF-16 length of every text
    ///     chunk successfully live-inserted this session.
    static func computeDecision(
        rawText: String,
        processedText: String,
        fieldValue: String,
        startCaret: Int,
        insertedUTF16Length: Int
    ) -> Decision {
        // No dictionary change → nothing to revise.
        guard processedText != rawText else {
            return .skip(reason: "processed text equals raw text")
        }

        // Nothing tracked as inserted → no span to revise.
        guard insertedUTF16Length > 0 else {
            return .skip(reason: "no text tracked as inserted this session")
        }

        let fieldNSString = fieldValue as NSString
        let fieldLength = fieldNSString.length

        // Defensive clamping: the field may have shrunk if the user deleted
        // content, or the tracked caret may be stale.
        let safeLocation = min(max(0, startCaret), fieldLength)
        let maxSpanLength = fieldLength - safeLocation
        let spanLength = min(max(0, insertedUTF16Length), maxSpanLength)

        // Critical safety guard: verify that the text currently occupying the
        // tracked span is exactly what we believe we inserted. If the user
        // edited the dictation, the field auto-corrected, characters were
        // dropped by the target, or the span tracking drifted, this check
        // fails and we leave the field untouched rather than risk corrupting
        // user text. (Design doc §1.5 / risk R1.)
        let actualSubstring = fieldNSString.substring(
            with: NSRange(location: safeLocation, length: spanLength)
        )
        guard actualSubstring == rawText else {
            return .skip(reason: "field content at tracked span does not match inserted text")
        }

        return .apply(replacement: processedText, location: safeLocation, length: spanLength)
    }
}

/// Outcome of executing the live auto-paste post-session sweep against the
/// target field. Returned by `TextInsertionService.performLiveAutoPasteSweep`.
enum LivePasteSweepOutcome: Equatable {
    /// The span was successfully revised with the dictionary-processed text.
    case applied
    /// The sweep correctly decided not to touch the field (no change needed,
    /// content mismatch, field unreadable, span unavailable, etc.). The raw
    /// text remains in the field.
    case skipped(reason: String)
    /// The sweep attempted to revise the field but could not safely complete
    /// (AX write failure, write did not verify, fallback failed). The raw
    /// text is left intact.
    case failed(reason: String)
}
