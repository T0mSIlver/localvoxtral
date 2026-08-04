#if LOCALVOXTRAL_DOGFOOD

import Foundation
import Synchronization

/// Side-channel for the two pipeline facts the commit path cannot see in its
/// own return values: WHY a join abstained, and WHAT the terminal-cwd repo
/// vocabulary harvested.
///
/// Both producers already reduce those facts to a log line before returning —
/// the resolver returns `nil` for every abstention cause, and the vocabulary
/// pipeline returns a `GroundingOutcome` that no longer carries its term pool.
/// Threading them through the return types would fork the production signatures
/// for a capture that shipped builds do not even compile, so a dogfood build
/// taps them here instead: producers note, the commit path consumes.
///
/// One dictation at a time by design (the commit path is serialized on the main
/// actor), so a single slot per fact is enough. `beginSession()` clears both
/// slots at dictation start; a fact noted by an abandoned pipeline after its
/// session's commit consumed the slot is cleared there rather than leaking into
/// the next record.
///
/// `Mutex` rather than an actor because the producers are on different
/// isolation domains: the resolver runs on the main actor, the repo-vocabulary
/// pipeline in a detached utility task.
final class DogfoodCaptureTap: Sendable {
    static let shared = DogfoodCaptureTap()

    private struct State {
        /// Which dictation the slots belong to. Bumped by `beginSession`, so a
        /// note carrying an older generation can be recognized as stale.
        var generation: UInt64 = 0
        var joinAbstentions: [String] = []
        var repoVocabularyHarvest: [String]?
    }

    private let state = Mutex(State())

    /// The generation a harvest note was created under. The repo-vocabulary
    /// pipeline is a DETACHED task racing `repoVocabularyPipelineDeadline`
    /// (3 s at the time of writing); when the deadline
    /// wins, the pipeline is abandoned but keeps running, and its eventual
    /// harvest note can land after the owning session already consumed — which
    /// would put session A's repo terms into session B's record, the exact
    /// bucket-1 misattribution the record exists to prevent (review, 2026-07-25).
    /// The commit path binds this task-local around the pipeline body at task
    /// creation (task-locals do not cross `Task.detached` on their own), and
    /// `noteRepoVocabularyHarvest` rejects a note whose generation has passed.
    /// Nil (an unbound caller, e.g. a direct unit test) is accepted as current.
    @TaskLocal static var noteGeneration: UInt64?

    /// Clears both slots and advances the generation. Called at dictation
    /// start, before the join resolves.
    func beginSession() {
        state.withLock {
            $0.generation &+= 1
            $0.joinAbstentions = []
            $0.repoVocabularyHarvest = nil
        }
    }

    var currentGeneration: UInt64 {
        state.withLock { $0.generation }
    }

    /// One arm's abstention cause, e.g. `"tty: stale"`. Accumulated: a single
    /// resolve can abstain on the tty arm and then again on the marker arm, and
    /// the record wants the whole story, not the last chapter.
    ///
    /// No generation check, deliberately: abstentions are noted synchronously
    /// on the main actor during session start, and overlapping session starts
    /// are blocked upstream — there is no abandoned producer to guard against.
    func noteJoinAbstention(_ cause: String) {
        state.withLock { $0.joinAbstentions.append(cause) }
    }

    /// The exact term pool the terminal-cwd repo vocabulary matched against.
    /// Dropped when `noteGeneration` says the note is from a session that has
    /// already ended — see `noteGeneration`.
    func noteRepoVocabularyHarvest(_ terms: [String]) {
        state.withLock {
            if let generation = Self.noteGeneration, generation != $0.generation {
                return
            }
            $0.repoVocabularyHarvest = terms
        }
    }

    /// All abstention causes noted since `beginSession`, oldest first, and
    /// clears them.
    func consumeJoinAbstentions() -> [String] {
        state.withLock {
            let causes = $0.joinAbstentions
            $0.joinAbstentions = []
            return causes
        }
    }

    /// The noted harvest, if any, and clears it.
    func consumeRepoVocabularyHarvest() -> [String]? {
        state.withLock {
            let harvest = $0.repoVocabularyHarvest
            $0.repoVocabularyHarvest = nil
            return harvest
        }
    }
}

/// Assembles a `DogfoodCaptureRecord` from the values the commit path already
/// holds, and derives the few record fields that are not literally one of them.
///
/// Pure and `nonisolated`: the harvest re-derivations walk complete retained
/// buffers (a clipboard can retain 2M characters), and the commit path is
/// `@MainActor` — so `build` is awaited off-actor exactly like the preparations
/// whose inputs it mirrors.
enum DogfoodCaptureBuilder {
    /// Harvest lists are capped in the RECORD, never in matching (which already
    /// ran). 500 terms is comfortably past where scanning a record stops being
    /// how anyone reviews it; `harvestTruncated` says the cap fired so a review
    /// never mistakes a truncated harvest for a retrieval miss.
    static let harvestTermCap = 500

    /// Screen text is capped at the AX reader's own retention cap; anything
    /// past it was never in memory to begin with, so this only guards against
    /// a future cap change silently growing records.
    static let sanitizedScreenTextCap = 32_000

    struct SourceInputs {
        var source: PolishContextSource
        var harvest: [String]
        var outcome: RepoVocabularyMatcher.GroundingOutcome
        var renderedExcerpt: String?
    }

    /// `host` class only, never the URL: `loopback`, `lan`, or `remote`.
    /// Deliberately coarse — the record needs "was this the bundled helper, a
    /// LAN box, or something else", not the user's network layout.
    static func endpointClass(of url: URL) -> String {
        if PolishContextClipboardReader.isLoopbackEndpoint(url) { return "loopback" }
        guard let host = url.host?.lowercased() else { return "remote" }
        if host.hasSuffix(".local") || host.hasPrefix("10.") || host.hasPrefix("192.168.") {
            return "lan"
        }
        if host.hasPrefix("172."),
           let second = host.split(separator: ".").dropFirst().first,
           let octet = Int(second), (16...31).contains(octet)
        {
            return "lan"
        }
        return "remote"
    }

    static func join(
        from join: ClaudeSessionJoin?,
        abstentions: [String]
    ) -> DogfoodCaptureRecord.Join {
        guard let join else {
            return DogfoodCaptureRecord.Join(
                arm: "none",
                abstentionReason: abstentions.isEmpty
                    ? nil : abstentions.joined(separator: "; "),
                origin: nil,
                terminal: nil,
                herdrBound: nil,
                workspaceIsLocal: nil
            )
        }
        let arm: String
        switch join.mechanism {
        case .ttyDevice: arm = "tty"
        case .titleMarker: arm = "titleMarker"
        case .herdrPane: arm = "herdrPane"
        case .browserTab: arm = "browserTab"
        case .cmuxSurface: arm = "cmuxSurface"
        case .remoteHerdrPane: arm = "remoteHerdrPane"
        }
        return DogfoodCaptureRecord.Join(
            arm: arm,
            // A resolved join can still have earlier arms' abstentions (tty
            // abstained, marker answered) — kept, because "the tty arm never
            // answers" is invisible in a record that only names the winner.
            abstentionReason: abstentions.isEmpty
                ? nil : abstentions.joined(separator: "; "),
            origin: join.snapshot.origin.isLocalAuthenticated ? "local" : "remote",
            terminal: join.target.bundleID,
            herdrBound: join.herdrPane != nil,
            workspaceIsLocal: join.snapshot.localWorkspacePath != nil
        )
    }

    static func screen(
        from decision: TerminalScreenContextDecision,
        targetBundleID: String?,
        socketPaneSwapApplied: Bool
    ) -> DogfoodCaptureRecord.Screen {
        let route: String?
        if socketPaneSwapApplied {
            // The swap only ever comes from the joined pane's own socket, so
            // the target app names which one answered.
            route = targetBundleID == TerminalScreenAllowlist.cmuxBundleID
                ? "cmuxSurfaceRead" : "herdrPaneRead"
        } else if let targetBundleID,
                  TerminalScreenAllowlist.axCaptureBundleIDs.contains(targetBundleID)
        {
            route = "axGrid"
        } else if let targetBundleID,
                  TerminalScreenAllowlist.appleScriptCaptureBundleIDs.contains(targetBundleID)
        {
            route = "appleScriptContents"
        } else {
            route = nil
        }

        switch decision {
        case let .render(excerpt, startText, elidedChurnLines):
            return screenRecord(
                route: route,
                decision: "render",
                cause: elidedChurnLines > 0 ? "elided-churn-lines:\(elidedChurnLines)" : nil,
                sanitizedText: startText.isEmpty ? excerpt : startText
            )
        case let .vocabularyOnly(startText, cause):
            return screenRecord(
                route: route,
                decision: "vocabularyOnly",
                cause: cause.summarySlug,
                sanitizedText: startText
            )
        case let .drop(reason):
            return screenRecord(
                route: route,
                decision: "drop",
                cause: reason.rawValue,
                sanitizedText: nil
            )
        }
    }

    private static func screenRecord(
        route: String?,
        decision: String,
        cause: String?,
        sanitizedText: String?
    ) -> DogfoodCaptureRecord.Screen {
        let truncated = (sanitizedText?.count ?? 0) > sanitizedScreenTextCap
        return DogfoodCaptureRecord.Screen(
            route: route,
            decision: decision,
            cause: cause,
            sanitizedCharacterCount: sanitizedText?.count ?? 0,
            sanitizedText: truncated
                ? sanitizedText.map { String($0.prefix(sanitizedScreenTextCap)) }
                : sanitizedText,
            sanitizedTextTruncated: truncated
        )
    }

    static func source(_ inputs: SourceInputs) -> DogfoodCaptureRecord.Source {
        let truncated = inputs.harvest.count > harvestTermCap
        return DogfoodCaptureRecord.Source(
            source: inputs.source.rawValue,
            harvest: truncated
                ? Array(inputs.harvest.prefix(harvestTermCap)) : inputs.harvest,
            harvestCount: inputs.harvest.count,
            harvestTruncated: truncated,
            entries: entries(inputs.outcome.entries),
            phoneticEntries: entries(inputs.outcome.phoneticEntries),
            verificationEntries: entries(inputs.outcome.verificationCandidates),
            isFallbackOnly: inputs.outcome.isFallbackOnly,
            renderedExcerpt: inputs.renderedExcerpt.flatMap { $0.isEmpty ? nil : $0 }
        )
    }

    private static func entries(
        _ entries: [ReplacementEntry]
    ) -> [DogfoodCaptureRecord.Source.Entry] {
        entries.map { .init(term: $0.replaceWith, heard: $0.matches) }
    }

    static func allocations(
        demands: [PolishContextSource: Int],
        grants: [PolishContextSource: Int],
        rendered: [PolishContextSource: Int]
    ) -> [DogfoodCaptureRecord.Allocation] {
        // Every source that DEMANDED, in allocation-rank order — a source
        // granted zero is the whole of bucket 4 and it leaves no other trace.
        PolishContextSource.allCases.compactMap { source in
            let demand = demands[source] ?? 0
            guard demand > 0 else { return nil }
            let grant = grants[source] ?? 0
            return DogfoodCaptureRecord.Allocation(
                source: source.rawValue,
                demandedCharacters: demand,
                grantedCharacters: grant,
                renderedCharacters: rendered[source] ?? 0,
                excerptWasSelected: demand > grant
            )
        }
    }

    /// The candidate term pool for a flat text source — the same derivation
    /// `ClipboardVocabulary.candidateOutcome` starts from, re-run here because
    /// the outcome discards it. Runs off-actor (this whole type does); a
    /// dogfood build pays this once per armed dictation and records the cost in
    /// `Timings.captureMilliseconds`.
    static func textSourceHarvest(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        return ClipboardVocabulary.entities(inExcerpt: text)
    }

    /// The joined-session repo's term pool — the exact list
    /// `ClaudeRepoContextPreparation.prepare` matched against.
    static func claudeRepoHarvest(_ snapshot: ClaudeRepoSnapshot?) -> [String] {
        guard let snapshot else { return [] }
        return ClaudeRepoContextPreparation.terms(
            from: ClaudeRepoContextPreparation.groundingSources(snapshot: snapshot)
        )
    }
}

/// Everything the polish commit path knows that a record needs, captured by
/// value so assembly can run off the main actor after the commit completed.
///
/// A nil text/snapshot means that source never ran this dictation and gets no
/// `Source` row; an empty-but-present one ran and harvested nothing, which is
/// exactly the retrieval evidence (bucket 1) the record exists to keep.
struct DogfoodCaptureInputs: Sendable {
    var session: DogfoodCaptureRecord.Session
    var join: ClaudeSessionJoin?
    var joinAbstentions: [String]
    var screenDecision: TerminalScreenContextDecision
    var socketPaneSwapApplied: Bool
    var targetBundleID: String?

    var demands: [PolishContextSource: Int]
    var grants: [PolishContextSource: Int]
    var rendered: [PolishContextSource: Int]

    /// The terminal-cwd repo vocabulary's term pool from the tap, nil when the
    /// pipeline never built a vocabulary.
    var repoVocabularyHarvest: [String]?
    var repoVocabularyOutcome: RepoVocabularyMatcher.GroundingOutcome
    var claudeRepoSnapshot: ClaudeRepoSnapshot?
    var claudeRepoOutcome: RepoVocabularyMatcher.GroundingOutcome
    var claudeRepoRenderedExcerpt: String?
    var claudeSessionText: String?
    var claudeSessionOutcome: RepoVocabularyMatcher.GroundingOutcome
    var claudeSessionRenderedExcerpt: String?
    var clipboardRetainedText: String?
    var clipboardOutcome: RepoVocabularyMatcher.GroundingOutcome
    var clipboardRenderedExcerpt: String?
    var screenOutcome: RepoVocabularyMatcher.GroundingOutcome
    var screenRenderedExcerpt: String?

    var text: DogfoodCaptureRecord.Text
    var polishSeconds: Double?
}

extension DogfoodCaptureBuilder {
    /// The full record, minus timings the caller measures around this call.
    ///
    /// Two `.repository` budget candidates exist (terminal-cwd vocabulary and
    /// the joined session's repo), so `Source` rows carry their OWN names —
    /// `repoVocabulary` / `claudeRepo` — while `Allocation` keeps the four
    /// budget sources. Collapsing the two would make a repoVocabulary matcher
    /// miss unattributable against a claudeRepo retrieval miss.
    nonisolated static func build(
        id: String,
        capturedAt: Date,
        inputs: DogfoodCaptureInputs
    ) -> DogfoodCaptureRecord {
        var sources: [DogfoodCaptureRecord.Source] = []

        if inputs.repoVocabularyHarvest != nil || !inputs.repoVocabularyOutcome.entries.isEmpty {
            var row = source(SourceInputs(
                source: .repository,
                harvest: inputs.repoVocabularyHarvest ?? [],
                outcome: inputs.repoVocabularyOutcome,
                renderedExcerpt: nil
            ))
            row.source = "repoVocabulary"
            sources.append(row)
        }
        if inputs.claudeRepoSnapshot != nil {
            var row = source(SourceInputs(
                source: .repository,
                harvest: claudeRepoHarvest(inputs.claudeRepoSnapshot),
                outcome: inputs.claudeRepoOutcome,
                renderedExcerpt: inputs.claudeRepoRenderedExcerpt
            ))
            row.source = "claudeRepo"
            sources.append(row)
        }
        if let screenText = inputs.screenDecision.vocabularyGroundingText {
            sources.append(source(SourceInputs(
                source: .terminal,
                harvest: textSourceHarvest(screenText),
                outcome: inputs.screenOutcome,
                renderedExcerpt: inputs.screenRenderedExcerpt
            )))
        }
        if let claudeText = inputs.claudeSessionText, !claudeText.isEmpty {
            sources.append(source(SourceInputs(
                source: .claude,
                harvest: textSourceHarvest(claudeText),
                outcome: inputs.claudeSessionOutcome,
                renderedExcerpt: inputs.claudeSessionRenderedExcerpt
            )))
        }
        if let clipboardText = inputs.clipboardRetainedText {
            sources.append(source(SourceInputs(
                source: .clipboard,
                harvest: textSourceHarvest(clipboardText),
                outcome: inputs.clipboardOutcome,
                renderedExcerpt: inputs.clipboardRenderedExcerpt
            )))
        }

        return DogfoodCaptureRecord(
            id: id,
            capturedAt: capturedAt,
            session: inputs.session,
            join: join(from: inputs.join, abstentions: inputs.joinAbstentions),
            screen: screen(
                from: inputs.screenDecision,
                targetBundleID: inputs.targetBundleID,
                socketPaneSwapApplied: inputs.socketPaneSwapApplied
            ),
            allocation: allocations(
                demands: inputs.demands,
                grants: inputs.grants,
                rendered: inputs.rendered
            ),
            sources: sources,
            text: inputs.text,
            timings: DogfoodCaptureRecord.Timings(
                polishSeconds: inputs.polishSeconds,
                captureMilliseconds: nil
            )
        )
    }
}

/// Writes one record, off the commit path's actor, never throwing into it.
///
/// The capture must be unable to break a dictation: a full disk, a foreign
/// directory owner, or an encoding surprise costs the RECORD (loudly), never
/// the commit. The write itself is synchronous file IO on the generic executor
/// — the user's text was already committed before the capture is assembled.
enum DogfoodCaptureWriter {
    /// Where the record landed, or nil when the write failed (loudly).
    @discardableResult
    nonisolated static func write(
        _ record: DogfoodCaptureRecord,
        store: DogfoodCaptureStore
    ) async -> URL? {
        do {
            let url = try store.write(record)
            Log.polishing.info(
                "Dogfood capture written: \(url.lastPathComponent, privacy: .public)"
            )
            return url
        } catch {
            // Loud by convention (AGENTS.md): a silent failure path here means
            // dogfooding quietly collects nothing.
            Log.polishing.error(
                "Dogfood capture write failed: \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }

    /// Patches one already-written record with the post-commit behavior signal.
    /// Off the commit path entirely — by the time this runs the dictation has
    /// been finished for seconds — and, like `write`, it can only ever cost the
    /// record.
    nonisolated static func attach(
        _ behavior: DogfoodCaptureRecord.Behavior,
        toRecordAt url: URL,
        store: DogfoodCaptureStore
    ) async {
        attachSynchronously(behavior, toRecordAt: url, store: store)
    }

    /// The same patch, without the hop. Used at app termination, where a `Task`
    /// is not guaranteed to run — see
    /// `DogfoodEditSignalWatcher.flushForTermination`. The work is one small
    /// JSON rewrite either way; only the caller's urgency differs.
    nonisolated static func attachSynchronously(
        _ behavior: DogfoodCaptureRecord.Behavior,
        toRecordAt url: URL,
        store: DogfoodCaptureStore
    ) {
        do {
            try store.attachBehavior(behavior, toRecordAt: url)
            Log.polishing.info(
                "Dogfood capture behavior: \(behavior.outcome.rawValue, privacy: .public) (\(behavior.signal?.rawValue ?? "none", privacy: .public), window \(behavior.watchWindowSeconds, privacy: .public)s) -> \(url.lastPathComponent, privacy: .public)"
            )
        } catch {
            Log.polishing.error(
                "Dogfood capture behavior patch failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }
}

#endif
