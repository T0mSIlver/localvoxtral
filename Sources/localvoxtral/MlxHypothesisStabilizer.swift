import Foundation

enum MlxInsertionMode {
    case realtime
    case finalized
    case none
}

@MainActor
final class MlxHypothesisStabilizer {
    struct StabilizationResult {
        let appendedDelta: String
        let unstableTail: String
    }

    struct PromotionResult {
        let allCommitted: String
        let newlyPromotedTail: String?
    }

    var onRealtimeInsertion: ((String) -> Void)?
    var onFinalizedInsertion: ((String) -> Void)?

    private(set) var committedEventText = ""
    private var committedSinceLastFinal = ""
    private var segmentLatestHypothesis = ""
    private var segmentPreviousHypothesis = ""
    private var segmentCommittedPrefix = ""

    func reset() {
        committedEventText = ""
        committedSinceLastFinal = ""
        segmentLatestHypothesis = ""
        segmentPreviousHypothesis = ""
        segmentCommittedPrefix = ""
    }

    func resetSegment() {
        committedSinceLastFinal = ""
        segmentLatestHypothesis = ""
        segmentPreviousHypothesis = ""
        segmentCommittedPrefix = ""
    }

    func consumeCommittedSinceLastFinal() -> String {
        let delta = committedSinceLastFinal
        committedSinceLastFinal = ""
        return delta
    }

    @discardableResult
    func commitHypothesis(
        _ hypothesis: String,
        isFinal: Bool,
        insertionMode: MlxInsertionMode
    ) -> StabilizationResult {
        guard !hypothesis.isEmpty else {
            return StabilizationResult(appendedDelta: "", unstableTail: "")
        }

        if isFinal,
           !segmentCommittedPrefix.isEmpty,
           !hypothesis.hasPrefix(segmentCommittedPrefix)
        {
            let safeDelta = resolvedFinalMismatchDelta(
                previousHypothesis: segmentLatestHypothesis,
                finalHypothesis: hypothesis
            )
            let appended = appendCommittedDeltaToEvent(
                safeDelta,
                insertionMode: insertionMode
            )
            segmentCommittedPrefix = hypothesis
            segmentLatestHypothesis = hypothesis
            segmentPreviousHypothesis = hypothesis
            return StabilizationResult(appendedDelta: appended, unstableTail: "")
        }

        let previousHypothesis = segmentPreviousHypothesis
        var commitTarget = segmentCommittedPrefix

        if isFinal {
            if hypothesis.hasPrefix(segmentCommittedPrefix) {
                commitTarget = hypothesis
            }
        } else if !previousHypothesis.isEmpty {
            let stableLength = TextMergingAlgorithms.longestCommonPrefixLength(
                lhs: previousHypothesis,
                rhs: hypothesis
            )
            let boundaryLength = TextMergingAlgorithms.stableWordBoundaryLength(in: hypothesis, upTo: stableLength)
            if boundaryLength > segmentCommittedPrefix.count {
                commitTarget = String(hypothesis.prefix(boundaryLength))
            }
        }

        var appendedDelta = ""
        if commitTarget.count > segmentCommittedPrefix.count,
           commitTarget.hasPrefix(segmentCommittedPrefix)
        {
            let start = commitTarget.index(
                commitTarget.startIndex,
                offsetBy: segmentCommittedPrefix.count
            )
            let newlyStableDelta = String(commitTarget[start...])
            appendedDelta = appendCommittedDeltaToEvent(
                newlyStableDelta,
                insertionMode: insertionMode
            )
            segmentCommittedPrefix = commitTarget
        }

        segmentLatestHypothesis = hypothesis
        segmentPreviousHypothesis = hypothesis

        let unstableTail: String
        if hypothesis.hasPrefix(segmentCommittedPrefix) {
            let start = hypothesis.index(
                hypothesis.startIndex,
                offsetBy: segmentCommittedPrefix.count
            )
            unstableTail = String(hypothesis[start...])
        } else {
            unstableTail = hypothesis
        }

        return StabilizationResult(appendedDelta: appendedDelta, unstableTail: unstableTail)
    }

    /// Promotes the remaining hypothesis tail when the server disconnects
    /// before emitting a final transcript. Returns only the unstabilized tail
    /// that was NOT already inserted via the realtime insertion queue.
    func promotePendingText() -> PromotionResult {
        let hypothesis = TextMergingAlgorithms.normalizeTranscriptionFormatting(
            segmentLatestHypothesis.trimmed
        )

        let alreadyInsertedPrefix = segmentCommittedPrefix

        if !hypothesis.isEmpty {
            _ = commitHypothesis(
                hypothesis,
                isFinal: true,
                insertionMode: .none
            )
        }

        let allCommitted = consumeCommittedSinceLastFinal().trimmed

        let newlyPromoted: String
        if hypothesis.count > alreadyInsertedPrefix.count,
           hypothesis.hasPrefix(alreadyInsertedPrefix)
        {
            let start = hypothesis.index(
                hypothesis.startIndex,
                offsetBy: alreadyInsertedPrefix.count
            )
            newlyPromoted = String(hypothesis[start...])
                .trimmed
        } else if alreadyInsertedPrefix.isEmpty {
            newlyPromoted = allCommitted
        } else {
            newlyPromoted = ""
        }

        return PromotionResult(
            allCommitted: allCommitted,
            newlyPromotedTail: newlyPromoted.isEmpty ? nil : newlyPromoted
        )
    }

    // MARK: - Private

    @discardableResult
    private func appendCommittedDeltaToEvent(
        _ delta: String,
        insertionMode: MlxInsertionMode
    ) -> String {
        guard !delta.isEmpty else { return "" }

        let merged = TextMergingAlgorithms.appendWithTailOverlap(existing: committedEventText, incoming: delta)
        committedEventText = merged.merged

        guard !merged.appendedDelta.isEmpty else { return "" }

        let finalizedDeltaBuffer = TextMergingAlgorithms.appendWithTailOverlap(
            existing: committedSinceLastFinal,
            incoming: merged.appendedDelta
        )
        committedSinceLastFinal = finalizedDeltaBuffer.merged

        switch insertionMode {
        case .realtime:
            onRealtimeInsertion?(merged.appendedDelta)
        case .finalized:
            onFinalizedInsertion?(merged.appendedDelta)
        case .none:
            break
        }

        return merged.appendedDelta
    }

    private func resolvedFinalMismatchDelta(
        previousHypothesis: String,
        finalHypothesis: String
    ) -> String {
        let previous = previousHypothesis.trimmed
        guard !previous.isEmpty else { return finalHypothesis }

        if finalHypothesis.hasPrefix(previous) {
            let start = finalHypothesis.index(finalHypothesis.startIndex, offsetBy: previous.count)
            return String(finalHypothesis[start...])
        }

        if previous.hasPrefix(finalHypothesis) || previous.contains(finalHypothesis) {
            return ""
        }

        if let range = finalHypothesis.range(of: previous) {
            return String(finalHypothesis[range.upperBound...])
        }

        let overlap = TextMergingAlgorithms.longestSuffixPrefixOverlap(
            lhs: previous,
            rhs: finalHypothesis
        )
        guard overlap > 0 else { return "" }
        let start = finalHypothesis.index(finalHypothesis.startIndex, offsetBy: overlap)
        return String(finalHypothesis[start...])
    }
}
