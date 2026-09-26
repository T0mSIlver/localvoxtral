import ClaudeContextWire
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
    struct StoppedSessionRecordFields {
        let startedAt: Date
        let provider: String
        let model: String
        let outputMode: String
        let targetAppBundleID: String?
        /// Taken at stop, before a polish that can outlast the next session's
        /// start.
        let audio: Data?
    }

    /// What an Overlay Buffer commit samples at the stop itself, before a
    /// second pass (#317) can hold the text back for seconds: the record's
    /// fields, and with a polishing configuration the world the polish is
    /// grounded in. The screen re-read compares against the start capture,
    /// and seconds of agent output scrolling past would drop it as mutated.
    struct OverlayStopSample {
        let record: StoppedSessionRecordFields
        let polishingConfig: LLMPolishingConfiguration?
        let capture: StopCommitCoordinator.Capture?
    }

    /// An Overlay Buffer session that was not cancelled: transcribed again
    /// first when the session has a second pass, then committed.
    private func commitOverlayBufferSession(sessionMode: DictationOutputMode) {
        if sessionIsQuickCapture {
            commitQuickCapture(sessionMode: sessionMode)
            return
        }
        let sessionAudio = audio.sessionRecording.finish()
        let polishingConfig = settings.llmPolishingConfiguration
        let sample = OverlayStopSample(
            record: StoppedSessionRecordFields(
                startedAt: sessionStartedAt ?? Date(),
                provider: sessionProvider?.rawValue ?? settings.realtimeProvider.rawValue,
                model: sessionModelName ?? settings.effectiveModelName,
                outputMode: sessionMode.rawValue,
                targetAppBundleID: resolveTargetAppBundleID(),
                audio: sessionStoresAudio ? sessionAudio : nil
            ),
            polishingConfig: polishingConfig,
            // The world as it was at stop: clipboard, screen, join and
            // pane, sampled together before any await.
            capture: polishingConfig.map {
                StopCommitCoordinator.capture(
                    endpointURL: $0.endpointURL,
                    settings: settings,
                    context: context,
                    pasteboardReader: dependencies.pasteboardReader
                )
            }
        )
        if let secondPass = stopSecondPassRequest(audio: sessionAudio, capture: sample.capture) {
            startStopSecondPass(secondPass, sessionMode: sessionMode, sample: sample)
            return
        }
        commitOverlayBufferText(sessionMode: sessionMode, sample: sample)
    }

    /// Polished and committed by a task when polishing has a configuration,
    /// committed as-is otherwise.
    func commitOverlayBufferText(
        sessionMode: DictationOutputMode,
        sample: OverlayStopSample,
        goToChecked: Bool = false
    ) {
        if !goToChecked, startGoToSessionIfSpoken(sessionMode: sessionMode, sample: sample) {
            return
        }
        // Before the dictionary and the polisher: the trigger is a command,
        // not text, so neither may see it.
        let spokenSend = stripOverlaySpokenSendTrigger()
        let preparation = StopCommitCoordinator.prepare(
            originalText: transcript.currentDictationEventText,
            polishingConfig: sample.polishingConfig,
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

        let capturedSessionStartedAt = sample.record.startedAt
        let capturedProvider = sample.record.provider
        let capturedModel = sample.record.model
        let capturedOutputMode = sample.record.outputMode
        let capturedTargetBundleID = sample.record.targetAppBundleID
        let capturedAudio = sample.record.audio
        // The capture exists exactly when the configuration does: both were
        // taken together at stop, ahead of the profile, which reads the join
        // the capture consumed.
        if let polishingConfig = preparation.polishingConfig, let capture = sample.capture {
            let polishProfile = StopCommitCoordinator.polishProfile(
                forTargetBundleID: capturedTargetBundleID,
                claudeJoin: capture.claudeJoin,
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

            // A value, not the join: the closure outlives the stop.
            let historyJoin = capture.claudeJoin.map(AgentCLIJoin.init)
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
                    clipboardPayload: clipboardPayload,
                    joined: historyJoin
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
                    spokenSend: spokenSend
                )
            }
            return
        }

        // Non-polishing overlay commit path
        // Read before the cleanup below discards the join; a capture taken
        // for a polish that could not run holds it instead.
        let historyJoin = (sample.capture?.claudeJoin ?? context.claudeSessionJoin).map(AgentCLIJoin.init)
        let overlayCommit = StopCommitCoordinator.commit(
            overlay: overlayBufferCoordinator,
            textInsertion: overlayTextCommitter,
            autoCopyEnabled: settings.autoCopyEnabled
        )
        if let failureMessage = overlayCommit.failureMessage {
            lastError = failureMessage
        }
        if overlayCommit.succeeded {
            // Read before the cleanup below discards the join.
            expectCorrection(of: displayWorkingText, join: context.claudeSessionJoin, project: nil)
            proposeProjectTermsIfNew(join: context.claudeSessionJoin, inserted: displayWorkingText)
        }
        sendOverlaySpokenSendIfNeeded(spokenSend, commit: overlayCommit)

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
            audio: capturedAudio,
            joined: historyJoin
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
        spokenSend: OverlaySpokenSend?
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
            textInsertion: self.overlayTextCommitter,
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
            self.proposeProjectTermsIfNew(join: capture.claudeJoin, inserted: insertedText)
        }
        self.sendOverlaySpokenSendIfNeeded(spokenSend, commit: overlayCommit)

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
            audio: record.audio,
            joined: capture.claudeJoin.map(AgentCLIJoin.init)
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
        let sessionAudio = audio.sessionRecording.finish()
        let capturedAudio = sessionStoresAudio ? sessionAudio : nil
        textInsertion.flushFinalLiveReplacementCorrections()
        let historyJoin = context.claudeSessionJoin.map(AgentCLIJoin.init)
        // Read before the cleanup below discards the join.
        if liveDictationCanTeachACorrection {
            expectCorrection(of: liveTypedText(), join: context.claudeSessionJoin, project: nil)
        }
        if !textInsertion.hasPendingInsertionText {
            proposeProjectTermsIfNew(join: context.claudeSessionJoin, inserted: liveTypedText())
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
            audio: capturedAudio,
            joined: historyJoin
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
        // After the last flush and any submit: calls already handed to the
        // relay still land, in order.
        textInsertion.endPromptRelay()

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
        joinedWorkspace: LocalWorkspacePath? = nil,
        repositoryRoot: RepoVocabularyRootBox? = nil
    ) async -> RepoVocabularyMatcher.GroundingOutcome? {
        await PolishContextGatherer.repoVocabularyGroundingIfEnabled(
            settings: settings,
            grounding: repoVocabularyGrounding,
            endpointURL: endpointURL,
            transcript: transcript,
            joinedWorkspace: joinedWorkspace,
            repositoryRoot: repositoryRoot
        )
    }


    /// A quick capture's stop (#725): the words are saved in History first,
    /// then handed to the Inbox; nothing is inserted, polished or sampled
    /// from the screen or the clipboard. The overlay closes as a cancelled
    /// one does.
    private func commitQuickCapture(sessionMode: DictationOutputMode) {
        let sessionAudio = audio.sessionRecording.finish()
        let text = transcript.currentDictationEventText.trimmingCharacters(in: .whitespacesAndNewlines)
        let recordID = UUID()
        let keptInHistory = !text.isEmpty && settings.dictationHistoryRetention.savesDictations && sessionStore != nil
        saveSessionRecord(
            id: recordID,
            startedAt: sessionStartedAt ?? Date(),
            rawText: text,
            polishedText: nil,
            polishingDuration: nil,
            provider: sessionProvider?.rawValue ?? settings.realtimeProvider.rawValue,
            model: sessionModelName ?? settings.effectiveModelName,
            outputMode: DictationSessionRecord.quickCaptureOutputMode,
            targetAppBundleID: nil,
            status: .sttCompleted,
            commitSucceeded: true,
            quickCaptureDestination: "Inbox",
            audio: sessionStoresAudio ? sessionAudio : nil,
            joined: nil
        )
        overlayBufferCoordinator.reset()
        completeStoppedSessionCleanup(sessionMode: sessionMode, overlayCommitOutcome: nil, shouldCommitOverlay: true)
        guard !text.isEmpty else {
            Log.dictation.info("quick capture: nothing was said")
            return
        }
        Log.dictation.info("quick capture: \(text.count, privacy: .public) chars to the inbox")
        statusText = StatusStrings.quickCaptureSaved
        onQuickCapture?(text, keptInHistory ? recordID : nil)
    }

    func saveSessionRecord(
        id: UUID = UUID(),
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
        quickCaptureDestination: String? = nil,
        audio: Data? = nil,
        joined: AgentCLIJoin?
    ) {
        let trimmedRawText = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRawText.isEmpty else {
            // Intentionally skip empty sessions: they produce no useful transcript payload.
            Log.persistence.debug("Skipping persistence for empty dictation session")
            return
        }
        let record = DictationSessionRecord(
            id: id,
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
            polishContextSummary: polishContextSummary,
            quickCaptureDestination: quickCaptureDestination
        )
        // What `localvoxtral history` and `status` report (#721): the
        // session's own directory or remote label, nothing read from disk.
        record.projectKey = joined?.project?.key
        record.projectName = joined?.project?.name
        record.joinedAgent = joined?.agent
        lastDictationJoin = joined
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

// MARK: - Second pass (#317)

/// An Overlay Buffer dictation in Mistral API mode is transcribed a second
/// time on stop, whole, by Mistral's batch model with the user's vocabulary
/// and, with the trusted-endpoint opt-in, this dictation's context (#647).
/// Its text replaces the realtime text only when it answers before a
/// deadline; the commit then goes on exactly as it would have.
extension DictationSessionController {
    struct StopSecondPassRequest {
        let wav: Data
        let audioSeconds: Double
        let apiKey: String
        let endpoint: URL
        let userTerms: [String]
        let dictionarySpellings: [String]
        let contextTrusted: Bool
        /// The session's and the screen's, read at stop. The repository's
        /// wait for the project, which may need the git root.
        let context: StopSecondPass.ContextTerms
        /// The joined session's workspace, the project's first word.
        let workspace: ClaudeWorkspaceReference?
        /// Whether the project's agent proposals may go, and so whether the
        /// git root is looked up: repo vocabulary on, and `contextTrusted`.
        let repositoryTermsPermitted: Bool
    }

    /// The list the pass is biased with, and the terms before
    /// `contextBias` joined their phrases, to put the spaces back.
    struct StopSecondPassTerms {
        let contextBias: [String]
        let candidates: [String]
    }

    /// Nil when this stop gets no second pass; every reason but "not this
    /// kind of session" is logged.
    ///
    /// `capture` is the stop sample's, taken before any wait; with no
    /// polishing configuration there is none, and the screen gives no terms.
    func stopSecondPassRequest(
        audio sessionAudio: Data?,
        capture: StopCommitCoordinator.Capture? = nil
    ) -> StopSecondPassRequest? {
        guard sessionHasStopSecondPass else { return nil }
        guard !transcript.currentDictationEventText
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            Log.backends.info("second pass skipped: the realtime transcript is empty")
            return nil
        }
        guard let pcm = sessionAudio, !pcm.isEmpty else {
            Log.backends.notice(
                "second pass skipped: no audio kept (over \(DictationAudioRecording.maxSeconds / 60, privacy: .public) min, or dropped)"
            )
            return nil
        }
        // The key and host the session dialed, never a fresh read of Settings.
        guard let configuration = sessionRealtimeConfiguration,
            !configuration.apiKey.isEmpty,
            let endpoint = MistralBatchTranscription.endpoint(
                forRealtimeEndpoint: configuration.endpoint)
        else {
            Log.backends.notice("second pass skipped: the session's endpoint has no batch route")
            return nil
        }
        let contextTrusted = PolishContextClipboardReader.isPermittedContextEndpoint(
            endpoint,
            trustedEndpointEnabled: settings.polishContextTrustedEndpointEnabled
        )
        // The join is the capture's, or with no polishing the one still on
        // the context.
        let join = capture?.claudeJoin ?? context.claudeSessionJoin
        return StopSecondPassRequest(
            wav: DictationAudioRecording.wav(fromPCM16: pcm),
            audioSeconds: Double(pcm.count) / Double(AudioChunkBuffer.bytesPerSecond),
            apiKey: configuration.apiKey,
            endpoint: endpoint,
            userTerms: settings.polishSpeakerTerms,
            dictionarySpellings: sessionReplacementDictionary?.entries.map(\.replaceWith) ?? [],
            contextTrusted: contextTrusted,
            context: contextTrusted
                ? stopSecondPassContextTerms(join: join, capture: capture, endpoint: endpoint)
                : .none,
            workspace: contextTrusted ? join?.snapshot.learnedTermWorkspace : nil,
            // An agent's unconfirmed proposals go only where repo vocabulary
            // may (#609): until use confirms them they are the repo's words.
            repositoryTermsPermitted: contextTrusted && settings.repoVocabularyEnabled
        )
    }

    /// The joined session's and the start screen's terms, from what the
    /// stop already holds. Each source passes the gate it passes for the
    /// polish, asked about `endpoint`.
    private func stopSecondPassContextTerms(
        join: ClaudeSessionJoin?,
        capture: StopCommitCoordinator.Capture?,
        endpoint: URL
    ) -> StopSecondPass.ContextTerms {
        var terms = StopSecondPass.ContextTerms()
        terms.session = StopSecondPass.speakableTerms(
            in: context.claudeSessionTextIfEnabled(join: join, endpointURL: endpoint))
        if let screen = capture?.screenDecision.vocabularyGroundingText {
            terms.screen = StopSecondPass.speakableTerms(in: screen, newestFirst: true)
        }
        return terms
    }

    /// The pass's terms, once the project is known. The project is the
    /// joined session's, widened to its repository by the git root (#652),
    /// or the focused terminal's repository with no join (#705). The root is
    /// looked up only when the project's proposals may go, and the stop
    /// waits for it at most `StopSecondPass.repositoryRootBound`; without
    /// it, a joined session keys on its own directory and an unjoined
    /// terminal has no project. The repository pipeline itself is not run:
    /// it can take 3 s, and it nominates only what the realtime text nearly
    /// spells.
    func stopSecondPassTerms(for request: StopSecondPassRequest) async -> StopSecondPassTerms {
        var context = request.context
        var learnedTerms: [String] = []
        if request.contextTrusted {
            var repositoryRoot = LearnedTermProjectResolver.RepositoryRoot.unknown
            if request.repositoryTermsPermitted, needsRepositoryRoot(request.workspace) {
                let started = ContinuousClock.now
                repositoryRoot = await repoVocabularyGrounding.repositoryRoot(
                    joinedWorkspace: request.workspace?.localPath,
                    sleep: dependencies.clock.sleep
                )
                Log.backends.info(
                    "second pass git root: \(Self.describe(repositoryRoot), privacy: .public) after \(String(format: "%.0f", (ContinuousClock.now - started) / .milliseconds(1)), privacy: .public) ms"
                )
            }
            let memory = learnedTermStore?.snapshot() ?? LearnedTerms()
            let project = LearnedTermProjectResolver.resolve(
                repositoryRoot: repositoryRoot, workspace: request.workspace)
            if let project {
                learnedTerms = memory.confirmedTerms(projectKey: project.key)
                if request.repositoryTermsPermitted {
                    context.repository = memory.unconfirmedProposals(projectKey: project.key)
                }
            }
            learnedTerms += memory.confirmedEverywhere().map(\.term)
        }
        let candidates = StopSecondPass.candidates(
            userTerms: request.userTerms,
            dictionarySpellings: request.dictionarySpellings,
            learnedTerms: learnedTerms,
            context: context,
            contextTrusted: request.contextTrusted
        )
        let contextBias = MistralBatchTranscription.contextBias(from: candidates)
        // Counts only: the terms are screen, session and repository content.
        Log.backends.info(
            "second pass terms: context \(request.contextTrusted ? "trusted" : "not sent", privacy: .public), repository \(context.repository.count, privacy: .public), session \(context.session.count, privacy: .public), screen \(context.screen.count, privacy: .public), sent \(contextBias.count, privacy: .public)"
        )
        return StopSecondPassTerms(contextBias: contextBias, candidates: candidates)
    }

    /// A remote session's project is its label, whatever this Mac's
    /// terminal sits in.
    private func needsRepositoryRoot(_ workspace: ClaudeWorkspaceReference?) -> Bool {
        if case .remoteOpaque = workspace { return false }
        return true
    }

    /// For the log: whether a root was found, never the path.
    private static func describe(_ root: LearnedTermProjectResolver.RepositoryRoot) -> String {
        switch root {
        case .unknown: "unknown"
        case .noRepository: "no repository"
        case .root(let path, let mainCheckout): path == mainCheckout ? "found" : "found, a linked worktree"
        }
    }

    /// Runs the second pass as the commit's task, then commits. A new
    /// dictation that cancels it saves the realtime text as not inserted,
    /// as it does for a polish.
    private func startStopSecondPass(
        _ request: StopSecondPassRequest,
        sessionMode: DictationOutputMode,
        sample: OverlayStopSample
    ) {
        statusText = StatusStrings.transcribingAgain
        let realtimeText = transcript.currentDictationEventText
        // Only what the history keeps: the closure outlives the stop, and a
        // join can hold an ssh forward open.
        let historyJoin = (sample.capture?.claudeJoin ?? context.claudeSessionJoin).map(AgentCLIJoin.init)
        saveInterruptedPolishCommit = { [weak self] in
            self?.saveSessionRecord(
                startedAt: sample.record.startedAt,
                rawText: realtimeText,
                polishedText: nil,
                polishingDuration: nil,
                provider: sample.record.provider,
                model: sample.record.model,
                outputMode: sample.record.outputMode,
                targetAppBundleID: sample.record.targetAppBundleID,
                status: .sttCompleted,
                commitSucceeded: false,
                audio: sample.record.audio,
                joined: historyJoin
            )
        }
        let deadline = StopSecondPass.deadline(audioSeconds: request.audioSeconds)
        let transcriber = dependencies.batchTranscriber
        let sleep = dependencies.clock.sleep
        let usageRecorder = secondPassUsageRecorder
        polishAndCommitTask = Task { @MainActor [weak self] in
            guard let terms = await self?.stopSecondPassTerms(for: request), !Task.isCancelled
            else { return }
            Log.backends.info(
                "second pass: sending \(String(format: "%.1f", request.audioSeconds), privacy: .public)s of audio with \(terms.contextBias.count, privacy: .public) terms, deadline \(String(describing: deadline), privacy: .public)"
            )
            let outcome = await StopSecondPass.run(deadline: deadline, sleep: sleep) {
                // Here, off the main actor: the ledger appends to its file
                // synchronously. Recorded as the request goes out, whatever
                // comes back: one the deadline cuts off may still be billed.
                usageRecorder?.record(MistralUsageEntry(
                    date: Date(),
                    kind: .retranscription,
                    model: MistralBatchTranscription.model,
                    audioSeconds: request.audioSeconds,
                    costEUR: MistralPricing.dictationCost(
                        model: MistralBatchTranscription.model, audioSeconds: request.audioSeconds)
                ))
                let text = try await transcriber.transcribe(
                    wav: request.wav,
                    language: nil,
                    contextBias: terms.contextBias,
                    apiKey: request.apiKey,
                    endpoint: request.endpoint
                ).text
                return MistralBatchTranscription.restoringPhrases(
                    in: text, candidates: terms.candidates)
            }
            guard let self, outcome != .cancelled, !Task.isCancelled else { return }
            self.applyStopSecondPass(outcome)
            self.commitOverlayBufferText(sessionMode: sessionMode, sample: sample)
            // The commit may hand off to a polish task; this one ends with it,
            // so whoever awaits the commit awaits all of it.
            await self.polishAndCommitTask?.value
        }
    }

    private func applyStopSecondPass(_ outcome: StopSecondPass.Outcome) {
        switch outcome {
        case .replaced(let text):
            Log.backends.info(
                "second pass replaced the realtime text (\(self.transcript.currentDictationEventText.count, privacy: .public) -> \(text.count, privacy: .public) chars)"
            )
            transcript.currentDictationEventText = text
            refreshOverlayBufferSession()
        case .empty:
            Log.backends.notice("second pass answered with no text; realtime text kept")
        case .deadlinePassed:
            Log.backends.notice("second pass missed its deadline; realtime text kept")
        case .failed(let reason):
            Log.backends.error("second pass failed; realtime text kept: \(reason, privacy: .public)")
        case .cancelled:
            break
        }
    }
}
