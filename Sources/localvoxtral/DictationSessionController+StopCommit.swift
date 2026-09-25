import Foundation
import os

/// The stop-commit: finishing a stopped session by output path, the overlay
/// commit and its polish task, the session record. What this file hands
/// `StopCommitCoordinator` (the transcript, the replacement dictionary the
/// session latched, the commit target whose bundle ID picks the profile)
/// decides what reaches the polisher, so the LLM lane filter names it; the
/// rest of the session does not trigger that lane.
extension DictationSessionController {
    func finishStoppedSession(promotePendingSegment: Bool) {
        guard !isCompletingStoppedSession else {
            debugLog("finishStoppedSession ignored; cleanup already in progress")
            return
        }
        isCompletingStoppedSession = true

        stopFinalizationTask?.cancel()
        stopFinalizationTask = nil
        finalizationWatchdogTask?.cancel()
        finalizationWatchdogTask = nil
        cancelConnectTimeout()
        cancelRealtimeReconnect()

        let sessionMode = sessionOutputMode ?? settings.dictationOutputMode
        let shouldCommitOverlay = sessionMode == .overlayBuffer

        if promotePendingSegment, !wasCancelled {
            _ = promotePendingRealtimeTextToLatestSegment()
        }

        // Cancelled overlay — dismiss immediately, no commit
        if shouldCommitOverlay, wasCancelled {
            _ = audio.sessionRecording.finish()
            overlayBufferCoordinator.reset()
            completeStoppedSessionCleanup(
                sessionMode: sessionMode,
                overlayCommitOutcome: nil,
                shouldCommitOverlay: true
            )
            return
        }

        if shouldCommitOverlay {
            commitOverlayBufferSession(sessionMode: sessionMode)
            return
        }

        finishLiveAutoPasteSession(sessionMode: sessionMode)
    }

    /// The record fields a stopped session samples at stop.
    private struct StoppedSessionRecordFields {
        let startedAt: Date
        let provider: String
        let model: String
        let outputMode: String
        let targetAppBundleID: String?
        /// Taken at stop, before a polish that can outlast the next session's
        /// start.
        let audio: Data?
    }

    /// An Overlay Buffer session that was not cancelled: polished and
    /// committed by a task when polishing has a configuration, committed
    /// as-is otherwise.
    private func commitOverlayBufferSession(sessionMode: DictationOutputMode) {
        // Before the dictionary and the polisher: the trigger is a command,
        // not text, so neither may see it.
        let spokenSendPID = stripOverlaySpokenSendTrigger()
        let preparation = StopCommitCoordinator.prepare(
            originalText: transcript.currentDictationEventText,
            latchedReplacementDictionary: sessionReplacementDictionary,
            settings: settings,
            appConfigStore: appConfigStore,
            pasteboardReader: dependencies.pasteboardReader
        )
        let originalText = preparation.originalText
        let workingText = preparation.workingText
        let clipboardPayload = preparation.clipboardPayload
        let payloadProvenanceSummary = preparation.payloadProvenanceSummary
        let llmConfigurationFailure = preparation.configurationFailure

        // Display the payload-substituted text (placeholder never shown to
        // the user); with no macro this is exactly `workingText`.
        let displayWorkingText = StopCommitCoordinator.substitutingPayload(
            workingText, payload: clipboardPayload
        )
        if transcript.currentDictationEventText != displayWorkingText {
            transcript.currentDictationEventText = displayWorkingText
        }
        refreshOverlayBufferSession()

        let capturedSessionStartedAt = sessionStartedAt ?? Date()
        let capturedProvider = sessionProvider?.rawValue ?? settings.realtimeProvider.rawValue
        let capturedModel = sessionModelName ?? settings.effectiveModelName
        let capturedOutputMode = sessionMode.rawValue
        let capturedTargetBundleID = resolveTargetAppBundleID()
        let capturedAudio = audio.sessionRecording.finish()
        if let polishingConfig = preparation.polishingConfig {
            let polishProfile = StopCommitCoordinator.polishProfile(
                forTargetBundleID: capturedTargetBundleID,
                settings: settings
            )
            Log.polishing.info(
                "Polish profile: \(polishProfile.rawValue, privacy: .public)"
            )
            let capturedPolishProfile = polishProfile.rawValue
            let promptTemplates = StopCommitCoordinator.promptTemplates(
                profile: polishProfile,
                settings: settings,
                appConfigStore: appConfigStore
            )

            statusText = StatusStrings.polishing
            debugLog("LLM polishing started for \(workingText.count) chars")

            // The world as it was at stop: clipboard, screen, join and
            // pane, sampled together before the task's awaits.
            let capture = StopCommitCoordinator.capture(
                endpointURL: polishingConfig.endpointURL,
                settings: settings,
                context: context,
                pasteboardReader: dependencies.pasteboardReader
            )

            saveInterruptedPolishCommit = { [weak self] in
                self?.saveSessionRecord(
                    startedAt: capturedSessionStartedAt,
                    rawText: originalText,
                    polishedText: workingText != originalText ? workingText : nil,
                    polishingDuration: nil,
                    provider: capturedProvider,
                    model: capturedModel,
                    outputMode: capturedOutputMode,
                    targetAppBundleID: capturedTargetBundleID,
                    status: .sttCompleted,
                    commitSucceeded: false,
                    polishContextSummary: payloadProvenanceSummary,
                    clipboardPayload: clipboardPayload
                )
            }
            polishAndCommitTask = Task { @MainActor [weak self] in
                guard let self else { return }
                await self.polishAndCommitOverlayBuffer(
                    sessionMode: sessionMode,
                    preparation: preparation,
                    polishingConfig: polishingConfig,
                    promptTemplates: promptTemplates,
                    capture: capture,
                    record: StoppedSessionRecordFields(
                        startedAt: capturedSessionStartedAt,
                        provider: capturedProvider,
                        model: capturedModel,
                        outputMode: capturedOutputMode,
                        targetAppBundleID: capturedTargetBundleID,
                        audio: capturedAudio
                    ),
                    polishProfile: capturedPolishProfile,
                    spokenSendPID: spokenSendPID
                )
            }
            return
        }

        // Non-polishing overlay commit path
        let overlayCommit = StopCommitCoordinator.commit(
            overlay: overlayBufferCoordinator,
            textInsertion: textInsertion,
            autoCopyEnabled: settings.autoCopyEnabled
        )
        if let failureMessage = overlayCommit.failureMessage {
            lastError = failureMessage
        }
        if overlayCommit.succeeded {
            // Read before the cleanup below discards the join.
            expectCorrection(of: displayWorkingText, join: context.claudeSessionJoin, project: nil)
        }
        pressOverlaySpokenSendReturnIfNeeded(pid: spokenSendPID, commit: overlayCommit)

        completeStoppedSessionCleanup(
            sessionMode: sessionMode,
            overlayCommitOutcome: overlayCommit.outcome,
            shouldCommitOverlay: true
        )

        saveSessionRecord(
            startedAt: capturedSessionStartedAt,
            rawText: originalText,
            // Persist the PLACEHOLDER-bearing working text, never the
            // payload; the payload lives only in the substituted commit copy.
            polishedText: workingText != originalText ? workingText : nil,
            polishingDuration: nil,
            provider: capturedProvider,
            model: capturedModel,
            outputMode: capturedOutputMode,
            targetAppBundleID: capturedTargetBundleID,
            status: llmConfigurationFailure == nil ? .sttCompleted : .llmFailed,
            commitSucceeded: overlayCommit.succeeded,
            polishContextSummary: payloadProvenanceSummary,
            clipboardPayload: clipboardPayload,
            audio: capturedAudio
        )

        if let llmConfigurationFailure {
            handleLLMPolishingConnectionFailure(
                message: llmConfigurationFailure.message,
                technicalDetails: llmConfigurationFailure.technicalDetails
            )
        }
    }

    /// The polish-and-commit task's body: polish, apply the reply, commit,
    /// record. Returns early, changing nothing, when the commit is cancelled.
    private func polishAndCommitOverlayBuffer(
        sessionMode: DictationOutputMode,
        preparation: StopCommitCoordinator.Preparation,
        polishingConfig: LLMPolishingConfiguration,
        promptTemplates: LLMPromptTemplates,
        capture: StopCommitCoordinator.Capture,
        record: StoppedSessionRecordFields,
        polishProfile capturedPolishProfile: String,
        spokenSendPID: pid_t?
    ) async {
        let originalText = preparation.originalText
        let workingText = preparation.workingText
        let payloadProvenanceSummary = preparation.payloadProvenanceSummary
        let capturedSessionStartedAt = record.startedAt
        let capturedProvider = record.provider
        let capturedModel = record.model
        let capturedOutputMode = record.outputMode
        let capturedTargetBundleID = record.targetAppBundleID

        // Gather, assemble and send, with the same checkpoints; nil
        // means the commit was cancelled at one of them.
        guard let outcome = await StopCommitCoordinator.polish(
            StopCommitCoordinator.PolishInput(
                preparation: preparation,
                configuration: polishingConfig,
                promptTemplates: promptTemplates,
                capture: capture,
                settings: self.settings,
                textInsertion: self.textInsertion,
                context: self.context,
                repoVocabularyGrounding: self.repoVocabularyGrounding,
                learnedTermStore: self.learnedTermStore,
                service: self.llmPolishingService
            )
        ) else { return }
        let assembly = outcome.assembly

        var processedTextForPersistence: String? =
            workingText != originalText ? workingText : nil
        var polishingDuration: Double? = nil
        var sessionStatus: DictationSessionStatus = .completed
        var llmConnectionFailure: PolishOutcomeClassifier.Failure?
        #if LOCALVOXTRAL_DOGFOOD
        // The model's raw reply and the (placeholder-bearing)
        // committed text, for the capture record below.
        // Placeholder-bearing on purpose: the clipboard PAYLOAD
        // follows the session-record rule and never enters a
        // persisted record.
        var dogfoodPolishedOutput: String?
        var dogfoodCommittedText: String?
        #endif

        switch outcome.reply {
        case .notSent:
            break
        case .polished(let polished):
            polishingDuration = polished.durationSeconds
            let committedText = polished.committedText

            // Persist the PLACEHOLDER-bearing committed text —
            // the clipboard payload must never enter the session
            // record. Substitution happens only for the display/
            // commit copy below.
            processedTextForPersistence =
                committedText != originalText ? committedText : nil
            #if LOCALVOXTRAL_DOGFOOD
            dogfoodPolishedOutput = polished.polishedText
            dogfoodCommittedText = committedText
            #endif

            showPolishedText(polished, preparation: preparation)
        case .failed(let failure):
            sessionStatus = .llmFailed
            llmConnectionFailure = failure
        }

        guard !Task.isCancelled else { return }
        // From here the task commits and saves the dictation itself.
        self.saveInterruptedPolishCommit = nil

        let insertedText = self.transcript.currentDictationEventText
        let overlayCommit = StopCommitCoordinator.commit(
            overlay: self.overlayBufferCoordinator,
            textInsertion: self.textInsertion,
            autoCopyEnabled: self.settings.autoCopyEnabled
        )
        if let failureMessage = overlayCommit.failureMessage {
            self.lastError = failureMessage
        }
        if overlayCommit.succeeded {
            self.expectCorrection(
                of: insertedText,
                join: capture.claudeJoin,
                project: outcome.material.learnedProject
            )
        }
        self.pressOverlaySpokenSendReturnIfNeeded(pid: spokenSendPID, commit: overlayCommit)

        self.completeStoppedSessionCleanup(
            sessionMode: sessionMode,
            overlayCommitOutcome: overlayCommit.outcome,
            shouldCommitOverlay: true
        )

        self.saveSessionRecord(
            startedAt: capturedSessionStartedAt,
            rawText: originalText,
            polishedText: processedTextForPersistence,
            polishingDuration: polishingDuration,
            provider: capturedProvider,
            model: capturedModel,
            outputMode: capturedOutputMode,
            targetAppBundleID: capturedTargetBundleID,
            status: sessionStatus,
            commitSucceeded: overlayCommit.succeeded,
            polishProfile: capturedPolishProfile,
            polishContextSummary: StopCommitCoordinator.mergedPolishProvenanceSummary(
                context: assembly.polishContextSummary,
                payload: payloadProvenanceSummary,
                vocabulary: StopCommitCoordinator.vocabularyProvenance(
                    repoVocabularyCount: assembly.repoVocabularyCount,
                    clipboardVocabularyCount: assembly.clipboardVocabularyCount
                )
            ),
            clipboardPayload: preparation.clipboardPayload,
            audio: record.audio
        )

        #if LOCALVOXTRAL_DOGFOOD
        // AFTER the commit and the session record: capture latency
        // can only ever land on the tail of this task, never on the
        // user's paste. `writeDogfoodCaptureIfArmed` checks the
        // runtime opt-in before doing any work.
        await self.writeDogfoodCaptureIfArmed(
            StopCommitCoordinator.dogfoodCaptureInputs(
                material: outcome.material,
                assembly: assembly,
                capture: capture,
                targetBundleID: capturedTargetBundleID,
                targetIsTerminalLike: self.sessionTargetIsTerminalLike,
                outputMode: capturedOutputMode,
                promptProfile: capturedPolishProfile,
                polishingEndpointURL: polishingConfig.endpointURL,
                polishModel: polishingConfig.model,
                rawTranscript: originalText,
                workingText: workingText,
                polishedOutput: dogfoodPolishedOutput,
                committedText: dogfoodCommittedText,
                polishSeconds: polishingDuration
            ),
            commitOutcome: overlayCommit.outcome,
            // Substituted for MEASUREMENT only (the watch window
            // scales with what was inserted); the record keeps the
            // placeholder-bearing text above.
            committedTextForWatch: StopCommitCoordinator.substitutingPayload(
                dogfoodCommittedText ?? assembly.groundedWorkingText,
                payload: preparation.clipboardPayload
            )
        )
        #endif

        if let llmConnectionFailure {
            self.handleLLMPolishingConnectionFailure(
                title: llmConnectionFailure.title,
                message: llmConnectionFailure.message,
                technicalDetails: llmConnectionFailure.technicalDetails
            )
        }
    }

    /// What the user sees of a polished reply before the commit: the text in
    /// the overlay (payload substituted), the polished badge, and the raw
    /// transcript "Copy raw transcript" offers.
    private func showPolishedText(
        _ polished: StopCommitCoordinator.PolishOutcome.Polished,
        preparation: StopCommitCoordinator.Preparation
    ) {
        let committedText = polished.committedText
        let originalText = preparation.originalText
        let workingText = preparation.workingText
        self.transcript.currentDictationEventText = StopCommitCoordinator.substitutingPayload(
            committedText, payload: preparation.clipboardPayload
        )
        // Polish-changed iff the guarded/verified committed
        // text differs from the pre-grounding working text.
        // This intentionally counts an evidence-backed
        // deterministic spelling correction even when the
        // model otherwise returns its input unchanged.
        // Drives the overlay badge (during hold) and the
        // "Copy raw transcript" popover affordance.
        let polishChanged = committedText != workingText
        self.overlayBufferCoordinator.markPolished(polishChanged)
        // Retain the RAW (pre-everything) transcript for the
        // one-line popover copy affordance — but only when the
        // commit visibly changed it, so a no-op polish leaves
        // no stale affordance. Persisted `rawText` uses the
        // same `originalText`.
        self.lastPolishChangedRawTranscript =
            (polishChanged && originalText != committedText)
            ? originalText : nil
        self.refreshOverlayBufferSession()
        Log.polishing.info(
            "LLM polishing succeeded in \(String(format: "%.2f", polished.durationSeconds))s"
        )
    }

    /// A Live Auto-Paste session: the text is already typed, so what is left
    /// is the final flush and the record.
    private func finishLiveAutoPasteSession(sessionMode: DictationOutputMode) {
        // Non-overlay path (live auto-paste)
        let capturedSessionStartedAt = sessionStartedAt ?? Date()
        let capturedProvider = sessionProvider?.rawValue ?? settings.realtimeProvider.rawValue
        let capturedModel = sessionModelName ?? settings.effectiveModelName
        let capturedOutputMode = sessionMode.rawValue
        let capturedAudio = audio.sessionRecording.finish()
        textInsertion.flushFinalLiveReplacementCorrections()
        // Read before the cleanup below discards the join.
        if liveDictationCanTeachACorrection {
            expectCorrection(of: liveTypedText(), join: context.claudeSessionJoin, project: nil)
        }
        completeStoppedSessionCleanup(
            sessionMode: sessionMode,
            overlayCommitOutcome: nil,
            shouldCommitOverlay: false
        )

        saveSessionRecord(
            startedAt: capturedSessionStartedAt,
            rawText: transcript.currentDictationEventText,
            polishedText: nil,
            polishingDuration: nil,
            provider: capturedProvider,
            model: capturedModel,
            outputMode: capturedOutputMode,
            targetAppBundleID: nil,
            status: .sttCompleted,
            commitSucceeded: true,
            audio: capturedAudio
        )
    }

    func configureLiveAutoPasteReplacementCorrectorForSession() {
        resetLiveSpokenSendForSession()
        // The verdict below is taken once; focus can reach a terminal later.
        textInsertion.setLiveLateTerminalProbe(
            isLiveAutoPasteModeEnabled && !sessionTargetIsTerminalLike
                ? { [settings] in
                    TerminalTargetDetector.isCurrentTargetTerminalLike(
                        userBundleIDs: settings.userTerminalAppBundleIDs
                    )
                }
                : nil
        )
        guard isLiveAutoPasteModeEnabled else {
            textInsertion.endLiveReplacementSession()
            return
        }
        // Terminal-like targets always begin a live session even with the
        // dictionary disabled: the hold-back stream's newline/tab sanitization
        // must protect the terminal regardless of replacements.
        // The user's terms carry casing rules even with the dictionary toggle
        // off. Nothing to apply and not a terminal keeps the no-session path:
        // no hold-back, no delay.
        let dictionary = replacementDictionaryForCurrentSession()
        guard dictionary != nil || sessionTargetIsTerminalLike else {
            textInsertion.endLiveReplacementSession()
            return
        }

        overlayBufferCoordinator.captureLiveCommitTargetAppPID()
        textInsertion.beginLiveReplacementSession(
            dictionary: dictionary,
            preferredAppPID: overlayBufferCoordinator.commitTargetAppPID,
            isTerminalLikeTarget: sessionTargetIsTerminalLike
        )
    }

    func completeStoppedSessionCleanup(
        sessionMode: DictationOutputMode,
        overlayCommitOutcome: OverlayBufferCommitOutcome?,
        shouldCommitOverlay: Bool
    ) {
        wasCancelled = false
        isFinalizingStop = false
        isConnectingRealtimeSession = false
        isCompletingStoppedSession = false
        realtimeFinalizationLastActivityAt = nil
        polishAndCommitTask = nil
        saveInterruptedPolishCommit = nil
        liveSpokenSendSegmentMode = .undecided
        // Every stop funnels through here. The commit path has already
        // consumed the capture by now (it reconciles synchronously, before
        // spawning the polish Task), so this is a no-op there — it exists to
        // catch the stop paths that never reach the commit block at all: empty
        // transcript, polishing disabled, cancelled overlay.
        context.discardTerminalScreenCapture()
        clearLatchedSessionMetadata()
        if holdFailureIndicatorUntilStopCompletes {
            holdFailureIndicatorUntilStopCompletes = false
            markRecentConnectionFailureIndicator()
        } else {
            setRealtimeIndicatorIdle()
        }
        transcript.clearPending()
        switch overlayCommitOutcome {
        case .failed?:
            statusText = "Insert failed."
        case .copiedToClipboard?:
            statusText = StatusStrings.overlayCopiedToClipboard
        default:
            statusText = "Ready"
        }

        textInsertion.stopInsertionRetryTask()
        textInsertion.logDiagnostics()
        textInsertion.endLiveReplacementSession()

        if sessionMode == .liveAutoPaste, textInsertion.hasPendingInsertionText {
            lastError = "Some realtime text could not be inserted into the focused app."
            textInsertion.clearPendingText()
        }

        // Dismiss policy: a FAILED commit keeps its panel (the buffered text
        // may exist nowhere else); the secure-input clipboard fallback shows
        // its message for a readable hold and then dismisses — the text is
        // safe on the clipboard, and a panel that outlives the session read
        // as stuck in the field (owner feedback on #90).
        let dismissVisibility: TimeInterval?
        if !shouldCommitOverlay {
            dismissVisibility = TimingConstants.overlayFinalWordVisibilityMinimum
        } else {
            switch overlayCommitOutcome {
            case .failed?:
                dismissVisibility = nil
            case .copiedToClipboard?:
                dismissVisibility = TimingConstants.overlayClipboardFallbackVisibility
            default:
                dismissVisibility = TimingConstants.overlayFinalWordVisibilityMinimum
            }
        }
        if let dismissVisibility {
            overlayBufferCoordinator.dismissAfterHold(minimumVisibility: dismissVisibility)
        }

        if currentErrorToken == .websocketReceiveFailed {
            lastError = nil
        }
        // The Secure Keyboard Entry warning describes state sampled at session
        // start; a finished session must not leave it wedged in the popover —
        // nor keep the menu bar warning icon lit. (A REFUSED live start never
        // reaches this teardown; its icon clears when the shortcut release
        // ends the attempt gesture, and the popover line at the next start.)
        if currentErrorToken == .secureKeyboardEntryActive {
            lastError = nil
        }
        sessionSecureInputActive = false
        sessionClaudeJoinBadge = .hidden
        firstChunkPreprocessor.reset()
    }

    func resolveTargetAppBundleID() -> String? {
        guard let pid = overlayBufferCoordinator.commitTargetAppPID else { return nil }
        return dependencies.bundleIdentifier(pid)
    }

    /// The repository vocabulary for this commit, through the injected or
    /// production grounding.
    func repoVocabularyGroundingIfEnabled(
        endpointURL: URL,
        transcript: String,
        repositoryRoot: RepoVocabularyRootBox? = nil
    ) async -> RepoVocabularyMatcher.GroundingOutcome? {
        await PolishContextGatherer.repoVocabularyGroundingIfEnabled(
            settings: settings,
            grounding: repoVocabularyGrounding,
            endpointURL: endpointURL,
            transcript: transcript,
            repositoryRoot: repositoryRoot
        )
    }


    private func saveSessionRecord(
        startedAt: Date,
        rawText: String,
        polishedText: String?,
        polishingDuration: Double?,
        provider: String,
        model: String,
        outputMode: String,
        targetAppBundleID: String?,
        status: DictationSessionStatus,
        commitSucceeded: Bool,
        polishProfile: String? = nil,
        polishContextSummary: String? = nil,
        clipboardPayload: String? = nil,
        audio: Data? = nil
    ) {
        let trimmedRawText = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRawText.isEmpty else {
            // Intentionally skip empty sessions: they produce no useful transcript payload.
            Log.persistence.debug("Skipping persistence for empty dictation session")
            return
        }
        let record = DictationSessionRecord(
            startedAt: startedAt,
            finishedAt: Date(),
            rawText: rawText,
            polishedText: polishedText,
            polishingDurationSeconds: polishingDuration,
            provider: provider,
            model: model,
            outputMode: outputMode,
            targetAppBundleID: targetAppBundleID,
            status: status,
            commitSucceeded: commitSucceeded,
            polishProfile: polishProfile,
            polishContextSummary: polishContextSummary
        )
        dependencies.onSessionRecord?(record)
        let retention = settings.dictationHistoryRetention
        // The record holds the clipboard placeholder; the copy the user takes
        // gets the text as it was inserted.
        let entry = DictationHistoryEntry(record)
        rememberLastDictation(
            clipboardPayload == nil
                ? entry
                : entry.replacingPolishedText(entry.polishedText.map {
                    StopCommitCoordinator.substitutingPayload($0, payload: clipboardPayload)
                }),
            isInHistory: retention.savesDictations && sessionStore != nil
        )
        guard retention.savesDictations else {
            Log.persistence.debug("Dictation history is off: not saving this dictation")
            // Turning history off deleted what was there. If that write
            // failed, this is what tries again.
            applyDictationHistoryRetention(now: record.finishedAt)
            return
        }
        // Checked again here: the setting was latched at start, and turning
        // it off since has deleted the folder this would write into.
        sessionStore?.save(record, audio: settings.dictationAudioEnabled ? audio : nil)
        if let cutoff = retention.cutoff(now: record.finishedAt) {
            sessionStore?.trim(olderThan: cutoff)
        }
        termSuggestionCadence?.dictationSaved()
    }

    /// Brings the store in line with the retention setting: at launch, and
    /// when the setting changes. `off` deletes everything there is.
    func applyDictationHistoryRetention(now: Date = Date()) {
        let retention = settings.dictationHistoryRetention
        if !retention.savesDictations {
            // A pass already reading the history would send it to the hosted
            // model after the user said not to keep it.
            termSuggestions.stop()
        }
        guard let cutoff = retention.cutoff(now: now) else { return }
        sessionStore?.trim(olderThan: cutoff)
    }

    func replacementDictionaryForCurrentSession() -> ReplacementDictionary? {
        if let sessionReplacementDictionary {
            return sessionReplacementDictionary
        }
        let dictionary = StopCommitCoordinator.effectiveReplacementDictionary(
            settings: settings,
            appConfigStore: appConfigStore
        )
        sessionReplacementDictionary = dictionary
        return dictionary
    }
}
