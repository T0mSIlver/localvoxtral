import Carbon.HIToolbox
import Foundation
import XCTest
@testable import localvoxtral

@MainActor
final class DictationViewModelOverlayLifecycleTests: XCTestCase {
    // DictationViewModel owns several app-lifetime services. Retain test instances
    // for the process duration so teardown does not race service shutdown.
    private static var retainedViewModels: [DictationViewModel] = []

    func testSessionOutputModeIsLatchedWhileSessionIsActive() {
        let settings = makeSettings(outputMode: .overlayBuffer)
        let overlayCoordinator = MockOverlayCoordinator()
        let viewModel = DictationViewModel(
            settings: settings,
            overlayBufferCoordinator: overlayCoordinator,
            startRuntimeServices: false
        )
        retainForTestProcessLifetime(viewModel)

        viewModel.sessionOutputMode = .overlayBuffer
        settings.dictationOutputMode = .liveAutoPaste

        XCTAssertTrue(viewModel.isOverlayBufferModeEnabled)
        XCTAssertFalse(viewModel.isLiveAutoPasteModeEnabled)

        viewModel.sessionOutputMode = nil

        XCTAssertFalse(viewModel.isOverlayBufferModeEnabled)
        XCTAssertTrue(viewModel.isLiveAutoPasteModeEnabled)
    }

    func testExplicitOutputModeSurvivesBeginDictationSession() async {
        let settings = makeSettings(outputMode: .liveAutoPaste)
        settings.realtimeAPIEndpointURL = "ws://127.0.0.1:1/realtime"
        let overlayCoordinator = MockOverlayCoordinator()
        let viewModel = DictationViewModel(
            settings: settings,
            overlayBufferCoordinator: overlayCoordinator,
            startRuntimeServices: false
        )
        retainForTestProcessLifetime(viewModel)

        await viewModel.beginDictationSession(outputMode: .overlayBuffer)

        XCTAssertEqual(viewModel.sessionOutputMode, .overlayBuffer)
        XCTAssertTrue(viewModel.isOverlayBufferModeEnabled)
        XCTAssertFalse(viewModel.isLiveAutoPasteModeEnabled)

        viewModel.abortConnectingSession()
    }

    func testStopWithoutFinalizationStillCommitsOverlayUsingLatchedSessionMode() {
        let settings = makeSettings(outputMode: .overlayBuffer)
        let overlayCoordinator = MockOverlayCoordinator()
        let viewModel = DictationViewModel(
            settings: settings,
            overlayBufferCoordinator: overlayCoordinator,
            startRuntimeServices: false
        )
        retainForTestProcessLifetime(viewModel)

        viewModel.sessionOutputMode = .overlayBuffer
        settings.dictationOutputMode = .liveAutoPaste
        viewModel.isDictating = true
        viewModel.currentDictationEventText = "hello"
        viewModel.pendingSegmentText = " world"

        viewModel.stopDictation(reason: "test", finalizeRemainingAudio: false)

        XCTAssertEqual(overlayCoordinator.refreshCalls.count, 1)
        XCTAssertEqual(overlayCoordinator.refreshCalls.last?.displayText, "hello world")
        XCTAssertEqual(overlayCoordinator.refreshCalls.last?.commitText, "hello\nworld")
        XCTAssertEqual(overlayCoordinator.commitCallCount, 1)
        XCTAssertEqual(overlayCoordinator.dismissAfterHoldCallCount, 1)
        XCTAssertEqual(overlayCoordinator.resetCallCount, 0)
        XCTAssertEqual(viewModel.statusText, "Ready")
        XCTAssertNil(viewModel.sessionOutputMode)
    }

    func testFinishStoppedSessionCommitFailureKeepsOverlayVisible() {
        let settings = makeSettings(outputMode: .overlayBuffer)
        let overlayCoordinator = MockOverlayCoordinator()
        overlayCoordinator.commitOutcome = .failed(message: "Unable to insert buffered text into the focused app.")
        let viewModel = DictationViewModel(
            settings: settings,
            overlayBufferCoordinator: overlayCoordinator,
            startRuntimeServices: false
        )
        retainForTestProcessLifetime(viewModel)

        viewModel.sessionOutputMode = .overlayBuffer
        viewModel.isFinalizingStop = true
        viewModel.currentDictationEventText = "hello"

        viewModel.finishStoppedSession(promotePendingSegment: false)

        XCTAssertEqual(overlayCoordinator.refreshCalls.count, 1)
        XCTAssertEqual(overlayCoordinator.commitCallCount, 1)
        XCTAssertEqual(overlayCoordinator.resetCallCount, 0)
        XCTAssertEqual(viewModel.statusText, "Insert failed.")
        XCTAssertEqual(viewModel.lastError, "Unable to insert buffered text into the focused app.")
        XCTAssertNil(viewModel.sessionOutputMode)
    }

    func testTranscriptionFinalizedDisconnectsImmediatelyDuringFinalization() async {
        let settings = makeSettings(outputMode: .overlayBuffer)
        let overlayCoordinator = MockOverlayCoordinator()
        let viewModel = DictationViewModel(
            settings: settings,
            overlayBufferCoordinator: overlayCoordinator,
            startRuntimeServices: false
        )
        retainForTestProcessLifetime(viewModel)

        let session = URLSession(configuration: .ephemeral)
        let task = session.webSocketTask(with: URL(string: "ws://127.0.0.1:65535/test")!)
        defer {
            task.cancel()
            session.invalidateAndCancel()
        }

        viewModel.isFinalizingStop = true
        viewModel.sessionOutputMode = .overlayBuffer
        viewModel.realtimeAPIClient.debugPrimeConnectedStateForTesting(task: task)

        viewModel.handle(event: .transcriptionFinalized)

        let timeoutAt = Date().addingTimeInterval(1.0)
        while viewModel.isFinalizingStop, Date() < timeoutAt {
            try? await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertFalse(viewModel.isFinalizingStop)
        XCTAssertEqual(viewModel.statusText, "Ready")
        XCTAssertEqual(overlayCoordinator.commitCallCount, 1)
        XCTAssertEqual(overlayCoordinator.dismissAfterHoldCallCount, 1)
        XCTAssertEqual(
            overlayCoordinator.lastDismissAfterHoldMinimumVisibility,
            TimingConstants.overlayFinalWordVisibilityMinimum
        )
        XCTAssertEqual(overlayCoordinator.resetCallCount, 0)
        XCTAssertFalse(viewModel.realtimeAPIClient.isConnected)
    }

    func testPushToTalkReleaseWhileConnectingStillSurfacesTimeoutFailure() async {
        let settings = makeSettings(outputMode: .liveAutoPaste)
        settings.dictationShortcutMode = .pushToTalk
        let overlayCoordinator = MockOverlayCoordinator()
        let viewModel = DictationViewModel(
            settings: settings,
            overlayBufferCoordinator: overlayCoordinator,
            startRuntimeServices: false
        )
        retainForTestProcessLifetime(viewModel)

        // Prevent NSAlert from blocking test execution when the timeout path presents.
        viewModel.isShowingConnectionFailureAlert = true
        viewModel.isConnectingRealtimeSession = true
        viewModel.statusText = "Connecting to realtime backend..."
        viewModel.debugSetPushToTalkShortcutStateForTesting(isHeld: true, hasActiveSession: true)
        viewModel.scheduleConnectTimeout()

        viewModel.debugHandleDictationShortcutReleaseForTesting()

        XCTAssertTrue(viewModel.isConnectingRealtimeSession)
        XCTAssertEqual(viewModel.statusText, "Connecting to realtime backend...")

        let timeoutAt = Date().addingTimeInterval(TimingConstants.connectTimeout + 1.0)
        while viewModel.isConnectingRealtimeSession, Date() < timeoutAt {
            try? await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertFalse(viewModel.isConnectingRealtimeSession)
        XCTAssertEqual(viewModel.statusText, "Connection timed out.")
        XCTAssertEqual(viewModel.realtimeSessionIndicatorState, .recentFailure)
        XCTAssertNotNil(viewModel.lastError)
        XCTAssertTrue(
            viewModel.lastError?.contains(
                "No connection response received in \(Self.formattedTimeout(TimingConstants.connectTimeout))"
            ) == true
        )
    }

    func testPushToTalkReleaseBeforeConnectSkipsDictationStartOnConnectedEvent() {
        let settings = makeSettings(outputMode: .liveAutoPaste)
        settings.dictationShortcutMode = .pushToTalk
        let overlayCoordinator = MockOverlayCoordinator()
        let viewModel = DictationViewModel(
            settings: settings,
            overlayBufferCoordinator: overlayCoordinator,
            startRuntimeServices: false
        )
        retainForTestProcessLifetime(viewModel)

        viewModel.isConnectingRealtimeSession = true
        viewModel.statusText = "Connecting to realtime backend..."
        viewModel.debugSetPushToTalkShortcutStateForTesting(isHeld: true, hasActiveSession: true)

        viewModel.debugHandleDictationShortcutReleaseForTesting()
        viewModel.handle(event: .connected)

        XCTAssertFalse(viewModel.isConnectingRealtimeSession)
        XCTAssertFalse(viewModel.isDictating)
        XCTAssertEqual(viewModel.statusText, "Ready")
        XCTAssertEqual(viewModel.realtimeSessionIndicatorState, .idle)
    }

    func testModifierOnlyHoldReleaseBeforeConnectSkipsDictationStartOnConnectedEvent() {
        let settings = makeSettings(outputMode: .overlayBuffer)
        settings.modifierOnlyHotKeyEnabled = true
        let overlayCoordinator = MockOverlayCoordinator()
        let viewModel = DictationViewModel(
            settings: settings,
            overlayBufferCoordinator: overlayCoordinator,
            startRuntimeServices: false
        )
        retainForTestProcessLifetime(viewModel)

        viewModel.sessionOutputMode = .liveAutoPaste
        viewModel.isConnectingRealtimeSession = true
        viewModel.statusText = "Connecting to realtime backend..."
        viewModel.debugSetPushToTalkShortcutStateForTesting(isHeld: true, hasActiveSession: true)
        viewModel.debugSetModifierOnlyHoldStateForTesting(isActive: true)

        viewModel.debugHandleDictationShortcutReleaseForTesting()
        viewModel.handle(event: .connected)

        XCTAssertFalse(viewModel.isConnectingRealtimeSession)
        XCTAssertFalse(viewModel.isDictating)
        XCTAssertEqual(viewModel.statusText, "Ready")
        XCTAssertEqual(viewModel.realtimeSessionIndicatorState, .idle)
    }

    func testNoHotKeysRegisteredWhenOverlayAndLiveShortcutsAreDisabled() {
        HotKeyManager.debugResetOverridesForTesting()
        HotKeyManager.debugForceHandlerInstallResultForTesting(true)
        HotKeyManager.debugForceRegisterStatusForTesting(hotKeyID: .overlay, status: noErr)
        defer {
            HotKeyManager.debugResetOverridesForTesting()
        }

        let settings = makeSettings(outputMode: .overlayBuffer)
        settings.setDictationShortcut(SettingsStore.defaultDictationShortcut)
        settings.setOverlayBufferShortcut(nil)
        settings.setLivePasteShortcut(nil)
        // The subject is "no shortcuts left to register" — the modifier-only
        // gesture is a trigger of its own (seeded on for fresh installs), so it
        // has to be off too for there to be nothing to register.
        settings.modifierOnlyHotKeyEnabled = false
        let overlayCoordinator = MockOverlayCoordinator()
        let viewModel = DictationViewModel(
            settings: settings,
            overlayBufferCoordinator: overlayCoordinator,
            startRuntimeServices: false
        )
        retainForTestProcessLifetime(viewModel)

        viewModel.applyHotKeySettingsChange()

        XCTAssertEqual(viewModel.debugCurrentHotKeyRegistrationKindForTesting, .none)
        XCTAssertNil(viewModel.lastError)
    }

    func testCancelPolishingForNewSessionIfNeededResetsFinalizationState() {
        let settings = makeSettings(outputMode: .overlayBuffer)
        let overlayCoordinator = MockOverlayCoordinator()
        let viewModel = DictationViewModel(
            settings: settings,
            overlayBufferCoordinator: overlayCoordinator,
            startRuntimeServices: false
        )
        retainForTestProcessLifetime(viewModel)

        viewModel.sessionOutputMode = .overlayBuffer
        viewModel.isFinalizingStop = true
        viewModel.statusText = "Polishing..."
        let polishTask = Task<Void, Never> {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        viewModel.polishAndCommitTask = polishTask

        let cancelled = viewModel.cancelPolishingForNewSessionIfNeeded()

        XCTAssertTrue(cancelled)
        XCTAssertTrue(polishTask.isCancelled)
        XCTAssertNil(viewModel.polishAndCommitTask)
        XCTAssertFalse(viewModel.isFinalizingStop)
        XCTAssertNil(viewModel.sessionOutputMode)
        XCTAssertEqual(viewModel.statusText, "Ready")
        XCTAssertEqual(overlayCoordinator.resetCallCount, 1)
    }

    func testFinishStoppedSessionClearsStalePolishingTaskReference() {
        let settings = makeSettings(outputMode: .overlayBuffer)
        let overlayCoordinator = MockOverlayCoordinator()
        let viewModel = DictationViewModel(
            settings: settings,
            overlayBufferCoordinator: overlayCoordinator,
            startRuntimeServices: false
        )
        retainForTestProcessLifetime(viewModel)

        viewModel.sessionOutputMode = .overlayBuffer
        viewModel.isFinalizingStop = true
        viewModel.currentDictationEventText = "hello"
        viewModel.polishAndCommitTask = Task<Void, Never> {}

        viewModel.finishStoppedSession(promotePendingSegment: false)

        XCTAssertNil(viewModel.polishAndCommitTask)
        XCTAssertFalse(viewModel.isFinalizingStop)
    }

    func testFinishStoppedSessionIgnoresDuplicateCallsWhilePolishingIsInFlight() async {
        let settings = makeSettings(outputMode: .overlayBuffer)
        settings.llmPolishingEnabled = true
        settings.llmPolishingEndpointURL = "https://example.com/v1/chat/completions"

        let overlayCoordinator = MockOverlayCoordinator()
        let polishingService = BlockingMockLLMPolishingService()
        let viewModel = DictationViewModel(
            settings: settings,
            overlayBufferCoordinator: overlayCoordinator,
            startRuntimeServices: false
        )
        viewModel.llmPolishingService = polishingService
        retainForTestProcessLifetime(viewModel)

        viewModel.sessionOutputMode = .overlayBuffer
        viewModel.isFinalizingStop = true
        viewModel.currentDictationEventText = "hello world"

        viewModel.finishStoppedSession(promotePendingSegment: false)

        let firstCallDeadline = ContinuousClock.now + .seconds(1)
        while await polishingService.callCount() < 1, ContinuousClock.now < firstCallDeadline {
            try? await Task.sleep(for: .milliseconds(10))
        }

        let initialCallCount = await polishingService.callCount()
        XCTAssertEqual(initialCallCount, 1)
        XCTAssertTrue(viewModel.isCompletingStoppedSession)

        viewModel.finishStoppedSession(promotePendingSegment: false)
        viewModel.finishStoppedSession(promotePendingSegment: false)

        let duplicateCallCount = await polishingService.callCount()
        XCTAssertEqual(duplicateCallCount, 1)
        XCTAssertEqual(overlayCoordinator.commitCallCount, 0)

        await polishingService.resumePendingRequest()

        let finishDeadline = ContinuousClock.now + .seconds(1)
        while viewModel.isCompletingStoppedSession, ContinuousClock.now < finishDeadline {
            try? await Task.sleep(for: .milliseconds(10))
        }

        let finalCallCount = await polishingService.callCount()
        XCTAssertFalse(viewModel.isCompletingStoppedSession)
        XCTAssertEqual(finalCallCount, 1)
        XCTAssertEqual(overlayCoordinator.commitCallCount, 1)
    }

    func testFinishStoppedSessionAppliesReplacementDictionaryWithoutLLM() {
        let settings = makeSettings(outputMode: .overlayBuffer)
        settings.replacementDictionaryEnabled = true
        let overlayCoordinator = MockOverlayCoordinator()
        let viewModel = DictationViewModel(
            settings: settings,
            overlayBufferCoordinator: overlayCoordinator,
            startRuntimeServices: false
        )
        viewModel.appConfigStore = MockAppConfigStore(
            replacementDictionary: ReplacementDictionary(entries: [
                ReplacementEntry(replaceWith: "PostgreSQL", matches: ["postgres"]),
                ReplacementEntry(replaceWith: "localvoxtral", matches: ["local voxtral"]),
            ])
        )
        retainForTestProcessLifetime(viewModel)

        viewModel.sessionOutputMode = .overlayBuffer
        viewModel.isFinalizingStop = true
        viewModel.currentDictationEventText = "postgres for local voxtral"

        viewModel.finishStoppedSession(promotePendingSegment: false)

        XCTAssertEqual(viewModel.currentDictationEventText, "PostgreSQL for localvoxtral")
        XCTAssertEqual(overlayCoordinator.refreshCalls.last?.displayText, "PostgreSQL for localvoxtral")
        XCTAssertEqual(overlayCoordinator.refreshCalls.last?.commitText, "PostgreSQL for localvoxtral")
        XCTAssertEqual(overlayCoordinator.commitCallCount, 1)
        XCTAssertEqual(viewModel.statusText, "Ready")
    }

    func testOverlayStreamingReplacementUpdatesDisplayAtWordBoundary() {
        let settings = makeSettings(outputMode: .overlayBuffer)
        settings.replacementDictionaryEnabled = true
        let overlayCoordinator = MockOverlayCoordinator()
        let viewModel = DictationViewModel(
            settings: settings,
            overlayBufferCoordinator: overlayCoordinator,
            startRuntimeServices: false
        )
        viewModel.appConfigStore = MockAppConfigStore(
            replacementDictionary: ReplacementDictionary(entries: [
                ReplacementEntry(replaceWith: "PostgreSQL", matches: ["postgres"]),
            ])
        )
        retainForTestProcessLifetime(viewModel)

        viewModel.sessionOutputMode = .overlayBuffer
        viewModel.isDictating = true

        viewModel.handle(event: .partialTranscript("post"))
        viewModel.handle(event: .partialTranscript("gres "))

        XCTAssertEqual(overlayCoordinator.refreshCalls.map(\.displayText), [
            "post",
            "PostgreSQL ",
        ])
        XCTAssertEqual(overlayCoordinator.refreshCalls.map(\.commitText), [
            "post",
            "PostgreSQL ",
        ])
        XCTAssertEqual(viewModel.pendingSegmentText, "postgres ")
        XCTAssertEqual(viewModel.currentDictationEventText, "")
    }

    func testOverlayFinalizeDoesNotDoubleApplyStreamingReplacementAndSavesRawRecord() {
        let settings = makeSettings(outputMode: .overlayBuffer)
        settings.replacementDictionaryEnabled = true
        let overlayCoordinator = MockOverlayCoordinator()
        let viewModel = DictationViewModel(
            settings: settings,
            overlayBufferCoordinator: overlayCoordinator,
            startRuntimeServices: false
        )
        viewModel.appConfigStore = MockAppConfigStore(
            replacementDictionary: ReplacementDictionary(entries: [
                ReplacementEntry(replaceWith: "bar", matches: ["foo"]),
                ReplacementEntry(replaceWith: "baz", matches: ["bar"]),
            ])
        )
        var savedRecord: DictationSessionRecord?
        viewModel.debugSavedSessionRecordSink = { savedRecord = $0 }
        retainForTestProcessLifetime(viewModel)

        viewModel.sessionOutputMode = .overlayBuffer
        viewModel.isDictating = true
        viewModel.handle(event: .partialTranscript("foo "))
        viewModel.handle(event: .finalTranscript("foo "))
        viewModel.isDictating = false
        viewModel.isFinalizingStop = true

        viewModel.finishStoppedSession(promotePendingSegment: false)

        XCTAssertEqual(overlayCoordinator.refreshCalls.last?.displayText, "bar")
        XCTAssertEqual(overlayCoordinator.refreshCalls.last?.commitText, "bar")
        XCTAssertEqual(viewModel.currentDictationEventText, "bar")
        XCTAssertEqual(viewModel.transcriptText, "foo")
        XCTAssertEqual(savedRecord?.rawText, "foo")
        XCTAssertEqual(savedRecord?.polishedText, "bar")
        XCTAssertEqual(overlayCoordinator.commitCallCount, 1)
    }

    // MARK: - F6: polished badge flag + raw-transcript copy affordance

    /// Shared completion wait for the F6 tests (poll-with-deadline, matching
    /// the file's existing pattern). Known debt: the whole file's completion
    /// waiting is wall-clock polling rather than an injected clock — new tests
    /// at least share one helper instead of inlining more copies.
    private func waitUntilStoppedSessionCompletes(_ viewModel: DictationViewModel) async {
        let deadline = ContinuousClock.now + .seconds(1)
        while viewModel.isCompletingStoppedSession, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    func testPolishChangedCommitFlagsBadgeAndRetainsRawTranscript() async {
        let settings = makeSettings(outputMode: .overlayBuffer)
        settings.llmPolishingEnabled = true
        settings.llmPolishingEndpointURL = "https://example.com/v1/chat/completions"

        let overlayCoordinator = MockOverlayCoordinator()
        let polishingService = CapturingMockLLMPolishingService(resultText: "Hello world.")
        let viewModel = DictationViewModel(
            settings: settings,
            overlayBufferCoordinator: overlayCoordinator,
            startRuntimeServices: false
        )
        viewModel.appConfigStore = MockAppConfigStore()
        viewModel.llmPolishingService = polishingService
        retainForTestProcessLifetime(viewModel)

        viewModel.sessionOutputMode = .overlayBuffer
        viewModel.isFinalizingStop = true
        viewModel.currentDictationEventText = "hello world"

        viewModel.finishStoppedSession(promotePendingSegment: false)

        await waitUntilStoppedSessionCompletes(viewModel)

        XCTAssertEqual(viewModel.currentDictationEventText, "Hello world.")
        XCTAssertEqual(
            overlayCoordinator.markPolishedCalls.last, true,
            "the overlay must be told the polish changed the text so it shows the badge"
        )
        XCTAssertEqual(
            viewModel.lastPolishChangedRawTranscript, "hello world",
            "the RAW pre-polish transcript is retained for the popover copy affordance"
        )
        XCTAssertTrue(viewModel.canCopyRawTranscript)
    }

    func testUnchangedPolishOffersNoBadgeOrRawCopy() async {
        let settings = makeSettings(outputMode: .overlayBuffer)
        settings.llmPolishingEnabled = true
        settings.llmPolishingEndpointURL = "https://example.com/v1/chat/completions"

        let overlayCoordinator = MockOverlayCoordinator()
        // The model returns the input verbatim — no visible change to annotate.
        let polishingService = CapturingMockLLMPolishingService(resultText: "hello world")
        let viewModel = DictationViewModel(
            settings: settings,
            overlayBufferCoordinator: overlayCoordinator,
            startRuntimeServices: false
        )
        viewModel.appConfigStore = MockAppConfigStore()
        viewModel.llmPolishingService = polishingService
        // Seed a stale affordance to prove the unchanged commit clears it.
        viewModel.lastPolishChangedRawTranscript = "stale raw"
        retainForTestProcessLifetime(viewModel)

        viewModel.sessionOutputMode = .overlayBuffer
        viewModel.isFinalizingStop = true
        viewModel.currentDictationEventText = "hello world"

        viewModel.finishStoppedSession(promotePendingSegment: false)

        await waitUntilStoppedSessionCompletes(viewModel)

        XCTAssertEqual(overlayCoordinator.markPolishedCalls.last, false)
        XCTAssertNil(viewModel.lastPolishChangedRawTranscript)
        XCTAssertFalse(viewModel.canCopyRawTranscript)
    }

    func testCopyRawTranscriptWritesRawTextThroughPasteboardSeam() {
        let settings = makeSettings(outputMode: .overlayBuffer)
        let viewModel = DictationViewModel(
            settings: settings,
            overlayBufferCoordinator: MockOverlayCoordinator(),
            startRuntimeServices: false
        )
        retainForTestProcessLifetime(viewModel)

        var written: [String] = []
        viewModel.debugPasteboardWriteOverride = { written.append($0) }

        // Nothing retained: the action is a no-op and writes nothing.
        XCTAssertFalse(viewModel.canCopyRawTranscript)
        viewModel.copyRawTranscript()
        XCTAssertTrue(written.isEmpty)

        viewModel.lastPolishChangedRawTranscript = "the raw words"
        XCTAssertTrue(viewModel.canCopyRawTranscript)
        viewModel.copyRawTranscript()

        XCTAssertEqual(written, ["the raw words"], "the RAW transcript is what lands on the clipboard")
        XCTAssertEqual(viewModel.statusText, "Raw transcript copied.")
    }

    func testFinishStoppedSessionSendsReplacementDictionaryInLLMRequest() async {
        let settings = makeSettings(outputMode: .overlayBuffer)
        settings.replacementDictionaryEnabled = true
        settings.llmPolishingEnabled = true
        settings.llmPolishingEndpointURL = "https://example.com/v1/chat/completions"

        let overlayCoordinator = MockOverlayCoordinator()
        let polishingService = CapturingMockLLMPolishingService(resultText: "Polished text")
        let viewModel = DictationViewModel(
            settings: settings,
            overlayBufferCoordinator: overlayCoordinator,
            startRuntimeServices: false
        )
        viewModel.appConfigStore = MockAppConfigStore(
            replacementDictionary: ReplacementDictionary(entries: [
                ReplacementEntry(replaceWith: "PostgreSQL", matches: ["postgres"]),
            ]),
            promptTemplates: LLMPromptTemplates(
                systemContent: "system instructions",
                userContent: "{{replacement_dictionary}}\nWorking text:\n{{input_text}}"
            )
        )
        viewModel.llmPolishingService = polishingService
        retainForTestProcessLifetime(viewModel)

        viewModel.sessionOutputMode = .overlayBuffer
        viewModel.isFinalizingStop = true
        viewModel.currentDictationEventText = "postgres rocks"

        viewModel.finishStoppedSession(promotePendingSegment: false)

        let deadline = ContinuousClock.now + .seconds(1)
        while await polishingService.requestCount() < 1, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        while viewModel.isCompletingStoppedSession, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }

        let request = await polishingService.lastRequest()
        XCTAssertEqual(request?.inputText, "PostgreSQL rocks")
        XCTAssertEqual(request?.systemPrompt, "system instructions")
        XCTAssertEqual(
            request?.userPrompts,
            [
                "Replacement dictionary:\n- PostgreSQL: postgres\nWorking text:\nPostgreSQL rocks"
            ]
        )
        XCTAssertEqual(overlayCoordinator.commitCallCount, 1)
    }

    func testFinishStoppedSessionLLMPolishingSendsDictionaryWithoutLocalExactReplacement() async {
        let settings = makeSettings(outputMode: .overlayBuffer)
        settings.replacementDictionaryEnabled = false
        settings.llmPolishingEnabled = true
        settings.llmPolishingEndpointURL = "https://example.com/v1/chat/completions"

        let overlayCoordinator = MockOverlayCoordinator()
        let polishingService = CapturingMockLLMPolishingService(resultText: "Polished text")
        let configStore = MockAppConfigStore(
            replacementDictionary: ReplacementDictionary(entries: [
                ReplacementEntry(replaceWith: "PostgreSQL", matches: ["postgres"]),
            ]),
            promptTemplates: LLMPromptTemplates(
                systemContent: "system instructions",
                userContent: "{{replacement_dictionary}}\nWorking text:\n{{input_text}}"
            )
        )
        let viewModel = DictationViewModel(
            settings: settings,
            overlayBufferCoordinator: overlayCoordinator,
            startRuntimeServices: false
        )
        viewModel.appConfigStore = configStore
        viewModel.llmPolishingService = polishingService
        retainForTestProcessLifetime(viewModel)

        viewModel.sessionOutputMode = .overlayBuffer
        viewModel.isFinalizingStop = true
        viewModel.currentDictationEventText = "postgres rocks"

        viewModel.finishStoppedSession(promotePendingSegment: false)

        let deadline = ContinuousClock.now + .seconds(1)
        while await polishingService.requestCount() < 1, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        while viewModel.isCompletingStoppedSession, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }

        let request = await polishingService.lastRequest()
        XCTAssertEqual(configStore.loadReplacementDictionaryCallCount, 1)
        XCTAssertEqual(request?.inputText, "postgres rocks")
        XCTAssertEqual(
            request?.userPrompts,
            [
                "Replacement dictionary:\n- PostgreSQL: postgres\nWorking text:\npostgres rocks"
            ]
        )
    }

    func testFinishStoppedSessionLLMFailureKeepsLocalReplacement() async {
        let settings = makeSettings(outputMode: .overlayBuffer)
        settings.replacementDictionaryEnabled = true
        settings.llmPolishingEnabled = true
        settings.llmPolishingEndpointURL = "https://example.com/v1/chat/completions"

        let overlayCoordinator = MockOverlayCoordinator()
        let polishingService = FailingMockLLMPolishingService()
        let viewModel = DictationViewModel(
            settings: settings,
            overlayBufferCoordinator: overlayCoordinator,
            startRuntimeServices: false
        )
        viewModel.appConfigStore = MockAppConfigStore(
            replacementDictionary: ReplacementDictionary(entries: [
                ReplacementEntry(replaceWith: "PostgreSQL", matches: ["postgres"]),
            ])
        )
        viewModel.llmPolishingService = polishingService
        retainForTestProcessLifetime(viewModel)

        viewModel.sessionOutputMode = .overlayBuffer
        viewModel.isFinalizingStop = true
        viewModel.currentDictationEventText = "postgres"

        viewModel.finishStoppedSession(promotePendingSegment: false)

        let deadline = ContinuousClock.now + .seconds(1)
        while viewModel.isCompletingStoppedSession, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(viewModel.currentDictationEventText, "PostgreSQL")
        XCTAssertEqual(overlayCoordinator.refreshCalls.last?.displayText, "PostgreSQL")
        XCTAssertEqual(overlayCoordinator.commitCallCount, 1)
        XCTAssertEqual(viewModel.statusText, "Ready")
    }

    func testFinishStoppedSessionLLMNetworkFailureSurfacesConnectionError() async {
        let settings = makeSettings(outputMode: .overlayBuffer)
        settings.replacementDictionaryEnabled = true
        settings.llmPolishingEnabled = true
        settings.llmPolishingEndpointURL = "https://example.com/v1/chat/completions"
        // Pin external mode so the configured endpoint above is the one the
        // request is sent to (and therefore the one the failure names). Under
        // managed mode this test used to pass only because the failure message
        // wrongly named the unused external-URL setting — the exact field bug
        // DictationViewModelPolishFailureDiagnosticsTests now covers.
        settings.polishingBackendMode = .externalURL

        let overlayCoordinator = MockOverlayCoordinator()
        let polishingService = NetworkFailingMockLLMPolishingService()
        let viewModel = DictationViewModel(
            settings: settings,
            overlayBufferCoordinator: overlayCoordinator,
            startRuntimeServices: false
        )
        viewModel.appConfigStore = MockAppConfigStore(
            replacementDictionary: ReplacementDictionary(entries: [
                ReplacementEntry(replaceWith: "PostgreSQL", matches: ["postgres"]),
            ])
        )
        viewModel.llmPolishingService = polishingService
        viewModel.isShowingConnectionFailureAlert = true
        retainForTestProcessLifetime(viewModel)

        viewModel.sessionOutputMode = .overlayBuffer
        viewModel.isFinalizingStop = true
        viewModel.currentDictationEventText = "postgres"

        viewModel.finishStoppedSession(promotePendingSegment: false)

        let deadline = ContinuousClock.now + .seconds(1)
        while viewModel.isCompletingStoppedSession, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(viewModel.currentDictationEventText, "PostgreSQL")
        XCTAssertEqual(overlayCoordinator.commitCallCount, 1)
        XCTAssertEqual(viewModel.statusText, "LLM polishing failed.")
        XCTAssertEqual(viewModel.realtimeSessionIndicatorState, .recentFailure)
        XCTAssertTrue(viewModel.lastError?.contains("Connection refused") == true)
        XCTAssertTrue(
            viewModel.lastError?.contains("https://example.com/v1/chat/completions") == true
        )
    }

    func testFinishStoppedSessionInvalidLLMEndpointSurfacesConnectionError() {
        let settings = makeSettings(outputMode: .overlayBuffer)
        settings.llmPolishingEnabled = true
        settings.llmPolishingEndpointURL = "not a url"
        // This test exercises external-mode endpoint validation (an invalid
        // URL surfaces a config error before polishing runs). Pin external
        // mode so the configured endpoint is validated; managed mode ignores
        // the user-typed endpoint and is covered at the SettingsStore level
        // (testLLMPolishingConfiguration_managedLocal_*).
        settings.polishingBackendMode = .externalURL

        let overlayCoordinator = MockOverlayCoordinator()
        let viewModel = DictationViewModel(
            settings: settings,
            overlayBufferCoordinator: overlayCoordinator,
            startRuntimeServices: false
        )
        viewModel.isShowingConnectionFailureAlert = true
        retainForTestProcessLifetime(viewModel)

        viewModel.sessionOutputMode = .overlayBuffer
        viewModel.isFinalizingStop = true
        viewModel.currentDictationEventText = "hello"

        viewModel.finishStoppedSession(promotePendingSegment: false)

        XCTAssertEqual(overlayCoordinator.commitCallCount, 1)
        XCTAssertEqual(viewModel.statusText, "LLM polishing failed.")
        XCTAssertEqual(viewModel.realtimeSessionIndicatorState, .recentFailure)
        XCTAssertEqual(
            viewModel.lastError,
            "Settings value could not be normalized to an HTTP endpoint URL."
        )
    }

    func testFinishStoppedSessionDoesNotLoadReplacementDictionaryInLiveMode() {
        let settings = makeSettings(outputMode: .liveAutoPaste)
        settings.replacementDictionaryEnabled = true
        let overlayCoordinator = MockOverlayCoordinator()
        let configStore = MockAppConfigStore(
            replacementDictionary: ReplacementDictionary(entries: [
                ReplacementEntry(replaceWith: "PostgreSQL", matches: ["postgres"]),
            ])
        )
        let viewModel = DictationViewModel(
            settings: settings,
            overlayBufferCoordinator: overlayCoordinator,
            startRuntimeServices: false
        )
        viewModel.appConfigStore = configStore
        retainForTestProcessLifetime(viewModel)

        viewModel.sessionOutputMode = .liveAutoPaste
        viewModel.isFinalizingStop = true
        viewModel.currentDictationEventText = "postgres"

        viewModel.finishStoppedSession(promotePendingSegment: false)

        XCTAssertEqual(configStore.loadReplacementDictionaryCallCount, 0)
        XCTAssertEqual(viewModel.currentDictationEventText, "postgres")
    }

    func testPrepareLLMPolishingPromptAccessSkipsPromptTemplatesWhenDisabled() {
        let settings = makeSettings(outputMode: .overlayBuffer)
        let overlayCoordinator = MockOverlayCoordinator()
        let configStore = MockAppConfigStore()
        let viewModel = DictationViewModel(
            settings: settings,
            overlayBufferCoordinator: overlayCoordinator,
            startRuntimeServices: false
        )
        viewModel.appConfigStore = configStore
        retainForTestProcessLifetime(viewModel)

        viewModel.prepareLLMPolishingPromptAccessIfNeeded()

        XCTAssertEqual(configStore.loadLLMPromptTemplatesCallCount, 0)
    }

    func testPrepareLLMPolishingPromptAccessLoadsPromptTemplatesWhenEnabled() {
        let settings = makeSettings(outputMode: .overlayBuffer)
        settings.llmPolishingEnabled = true
        let overlayCoordinator = MockOverlayCoordinator()
        let configStore = MockAppConfigStore()
        let viewModel = DictationViewModel(
            settings: settings,
            overlayBufferCoordinator: overlayCoordinator,
            startRuntimeServices: false
        )
        viewModel.appConfigStore = configStore
        retainForTestProcessLifetime(viewModel)

        viewModel.prepareLLMPolishingPromptAccessIfNeeded()

        XCTAssertEqual(configStore.loadLLMPromptTemplatesCallCount, 1)
    }

    func testUnexpectedDisconnectDuringDictationResetsEscapeCancelFlag() {
        // Regression: an unexpected realtime disconnect while actively dictating
        // tears down the session (sets isDictating = false). It must also stop
        // EscapeCancelHandler; otherwise the Carbon hotkey stays registered and
        // swallows Escape system-wide until the next session ends.
        let settings = makeSettings(outputMode: .overlayBuffer)
        let overlayCoordinator = MockOverlayCoordinator()
        let viewModel = DictationViewModel(
            settings: settings,
            overlayBufferCoordinator: overlayCoordinator,
            startRuntimeServices: false
        )
        retainForTestProcessLifetime(viewModel)

        viewModel.isDictating = true
        viewModel.sessionOutputMode = .overlayBuffer
        viewModel.currentDictationEventText = "hello"
        let stopCountBefore = EscapeCancelHandler.stopCallCount

        viewModel.handle(event: .disconnected)

        XCTAssertFalse(viewModel.isDictating)
        XCTAssertGreaterThan(EscapeCancelHandler.stopCallCount, stopCountBefore)
    }

    // The Escape Carbon hotkey is armed in a single shared code path
    // (startAudioCaptureAfterConnection) used by BOTH output modes and BOTH
    // shortcut modes (push-to-talk and toggle all funnel through
    // beginDictationSession -> connect -> startAudioCaptureAfterConnection).
    // What can regress is therefore the DISARM: every session-teardown path
    // must call escapeCancelHandler.stop(), otherwise Escape is swallowed
    // system-wide while the Carbon hotkey remains registered. These cover each
    // teardown path in both output modes.

    func testStopDictationClearsEscapeCancelArmingInOverlayBufferMode() {
        assertStopDictationClearsEscapeCancelArming(outputMode: .overlayBuffer)
    }

    func testStopDictationClearsEscapeCancelArmingInLiveAutoPasteMode() {
        assertStopDictationClearsEscapeCancelArming(outputMode: .liveAutoPaste)
    }

    private func assertStopDictationClearsEscapeCancelArming(outputMode: DictationOutputMode) {
        let settings = makeSettings(outputMode: outputMode)
        let overlayCoordinator = MockOverlayCoordinator()
        let viewModel = DictationViewModel(
            settings: settings,
            overlayBufferCoordinator: overlayCoordinator,
            startRuntimeServices: false
        )
        retainForTestProcessLifetime(viewModel)

        viewModel.isDictating = true
        viewModel.sessionOutputMode = outputMode
        let stopCountBefore = EscapeCancelHandler.stopCallCount

        viewModel.stopDictation(reason: "test", finalizeRemainingAudio: false)

        XCTAssertFalse(viewModel.isDictating)
        XCTAssertGreaterThan(EscapeCancelHandler.stopCallCount, stopCountBefore,
                             "escapeCancelHandler.stop() must run on session teardown in \(outputMode) mode")
    }

    func testCancelDictationClearsEscapeCancelArmingInOverlayBufferMode() {
        assertCancelDictationClearsEscapeCancelArming(outputMode: .overlayBuffer)
    }

    func testCancelDictationClearsEscapeCancelArmingInLiveAutoPasteMode() {
        assertCancelDictationClearsEscapeCancelArming(outputMode: .liveAutoPaste)
    }

    private func assertCancelDictationClearsEscapeCancelArming(outputMode: DictationOutputMode) {
        let settings = makeSettings(outputMode: outputMode)
        let overlayCoordinator = MockOverlayCoordinator()
        let viewModel = DictationViewModel(
            settings: settings,
            overlayBufferCoordinator: overlayCoordinator,
            startRuntimeServices: false
        )
        retainForTestProcessLifetime(viewModel)

        viewModel.isDictating = true
        viewModel.sessionOutputMode = outputMode
        let stopCountBefore = EscapeCancelHandler.stopCallCount

        viewModel.cancelDictation()

        XCTAssertFalse(viewModel.isDictating)
        XCTAssertGreaterThan(EscapeCancelHandler.stopCallCount, stopCountBefore,
                             "escapeCancelHandler.stop() must run on cancel in \(outputMode) mode")
    }

    func testAbortConnectingSessionClearsEscapeCancelArming() {
        // Escape is also armed-ready during the connecting phase: if the user
        // cancels (or Escape fires) while connecting, the connecting-session
        // teardown must still disarm so no stale armed state survives.
        let settings = makeSettings(outputMode: .overlayBuffer)
        let overlayCoordinator = MockOverlayCoordinator()
        let viewModel = DictationViewModel(
            settings: settings,
            overlayBufferCoordinator: overlayCoordinator,
            startRuntimeServices: false
        )
        retainForTestProcessLifetime(viewModel)

        viewModel.isConnectingRealtimeSession = true
        let stopCountBefore = EscapeCancelHandler.stopCallCount

        viewModel.abortConnectingSession()

        XCTAssertFalse(viewModel.isConnectingRealtimeSession)
        XCTAssertGreaterThan(EscapeCancelHandler.stopCallCount, stopCountBefore)
    }

    func testCancelWhileConnectingDoesNotLeakCancellationIntoNextSession() {
        // Cancelling during the connecting phase routes through
        // abortConnectingSession(), which never reaches stopped-session cleanup.
        // A leaked wasCancelled would make the NEXT session silently skip
        // segment promotion and the overlay commit, losing that dictation.
        let settings = makeSettings(outputMode: .overlayBuffer)
        let overlayCoordinator = MockOverlayCoordinator()
        let viewModel = DictationViewModel(
            settings: settings,
            overlayBufferCoordinator: overlayCoordinator,
            startRuntimeServices: false
        )
        retainForTestProcessLifetime(viewModel)

        viewModel.isConnectingRealtimeSession = true
        viewModel.cancelDictation()
        XCTAssertFalse(viewModel.wasCancelled)

        // Next session: a normal stop must still promote and commit.
        viewModel.sessionOutputMode = .overlayBuffer
        viewModel.isFinalizingStop = true
        viewModel.currentDictationEventText = "hello"
        viewModel.pendingSegmentText = " world"

        viewModel.finishStoppedSession(promotePendingSegment: true)

        XCTAssertEqual(viewModel.currentDictationEventText, "hello\nworld")
        XCTAssertEqual(overlayCoordinator.commitCallCount, 1)
    }

    func testCancelledOverlaySessionSkipsSegmentPromotionAndCommit() {
        // A cancelled overlay session must not promote the pending segment into
        // the buffer, must not commit/insert anything, and must reset the overlay
        // immediately. Compare with testStopWithoutFinalizationStillCommitsOverlayUsingLatchedSessionMode
        // (same setup minus wasCancelled), which commits.
        let settings = makeSettings(outputMode: .overlayBuffer)
        let overlayCoordinator = MockOverlayCoordinator()
        let viewModel = DictationViewModel(
            settings: settings,
            overlayBufferCoordinator: overlayCoordinator,
            startRuntimeServices: false
        )
        retainForTestProcessLifetime(viewModel)

        viewModel.sessionOutputMode = .overlayBuffer
        viewModel.isFinalizingStop = true
        viewModel.currentDictationEventText = "hello"
        viewModel.pendingSegmentText = " world"
        viewModel.wasCancelled = true

        viewModel.finishStoppedSession(promotePendingSegment: true)

        // Segment promotion skipped: display text never refreshed/merged.
        XCTAssertEqual(overlayCoordinator.refreshCalls.count, 0)
        XCTAssertEqual(viewModel.currentDictationEventText, "hello")
        // No insertion / commit, overlay torn down immediately.
        XCTAssertEqual(overlayCoordinator.commitCallCount, 0)
        XCTAssertEqual(overlayCoordinator.resetCallCount, 1)
        XCTAssertEqual(viewModel.statusText, "Ready")
        XCTAssertNil(viewModel.sessionOutputMode)
    }

    func testCancelDictationDuringActiveDictationStopsWithoutOverlayCommit() {
        let settings = makeSettings(outputMode: .overlayBuffer)
        let overlayCoordinator = MockOverlayCoordinator()
        let viewModel = DictationViewModel(
            settings: settings,
            overlayBufferCoordinator: overlayCoordinator,
            startRuntimeServices: false
        )
        retainForTestProcessLifetime(viewModel)

        viewModel.sessionOutputMode = .overlayBuffer
        viewModel.isDictating = true
        viewModel.currentDictationEventText = "hello"
        viewModel.pendingSegmentText = " world"

        viewModel.cancelDictation()

        // Cancellation routes through stopDictation(finalizeRemainingAudio: false),
        // which finalizes immediately with wasCancelled = true.
        XCTAssertFalse(viewModel.isDictating)
        XCTAssertFalse(viewModel.isFinalizingStop)
        XCTAssertEqual(overlayCoordinator.refreshCalls.count, 0)
        XCTAssertEqual(overlayCoordinator.commitCallCount, 0)
        XCTAssertEqual(overlayCoordinator.resetCallCount, 1)
        XCTAssertEqual(viewModel.statusText, "Ready")
    }

    func testCancelDictationIsNoOpWhenNoSessionActive() {
        let settings = makeSettings(outputMode: .overlayBuffer)
        let overlayCoordinator = MockOverlayCoordinator()
        let viewModel = DictationViewModel(
            settings: settings,
            overlayBufferCoordinator: overlayCoordinator,
            startRuntimeServices: false
        )
        retainForTestProcessLifetime(viewModel)

        viewModel.currentDictationEventText = "hello"

        viewModel.cancelDictation()

        // Guard rejects: nothing changed, no overlay churn.
        XCTAssertFalse(viewModel.wasCancelled)
        XCTAssertEqual(overlayCoordinator.resetCallCount, 0)
        XCTAssertEqual(overlayCoordinator.commitCallCount, 0)
        XCTAssertEqual(viewModel.currentDictationEventText, "hello")
    }

    private func makeSettings(outputMode: DictationOutputMode) -> SettingsStore {
        let suiteName = "localvoxtral.DictationViewModelOverlayLifecycleTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let settings = SettingsStore(defaults: defaults, environment: [:])
        settings.dictationOutputMode = outputMode
        return settings
    }

    private func retainForTestProcessLifetime(_ viewModel: DictationViewModel) {
        Self.retainedViewModels.append(viewModel)
    }

    private static func formattedTimeout(_ timeout: TimeInterval) -> String {
        let seconds = max(1, Int(timeout.rounded()))
        return "\(seconds) \(seconds == 1 ? "second" : "seconds")"
    }
}

private actor BlockingMockLLMPolishingService: LLMPolishingServicing {
    private var requests = 0
    private var continuation: CheckedContinuation<Void, Never>?

    func polish(
        request: LLMPolishingRequest,
        configuration _: LLMPolishingConfiguration
    ) async throws -> LLMPolishingResult {
        requests += 1
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
        return LLMPolishingResult(
            rawText: request.inputText,
            polishedText: "Hello world.",
            durationSeconds: 0.01
        )
    }

    func callCount() -> Int {
        requests
    }

    func resumePendingRequest() {
        continuation?.resume()
        continuation = nil
    }
}

private actor CapturingMockLLMPolishingService: LLMPolishingServicing {
    private let resultText: String
    private var requests: [LLMPolishingRequest] = []

    init(resultText: String) {
        self.resultText = resultText
    }

    func polish(
        request: LLMPolishingRequest,
        configuration _: LLMPolishingConfiguration
    ) async throws -> LLMPolishingResult {
        requests.append(request)
        return LLMPolishingResult(
            rawText: request.inputText,
            polishedText: resultText,
            durationSeconds: 0.01
        )
    }

    func requestCount() -> Int {
        requests.count
    }

    func lastRequest() -> LLMPolishingRequest? {
        requests.last
    }
}

private actor FailingMockLLMPolishingService: LLMPolishingServicing {
    func polish(
        request _: LLMPolishingRequest,
        configuration _: LLMPolishingConfiguration
    ) async throws -> LLMPolishingResult {
        throw MockPolishingError()
    }
}

private actor NetworkFailingMockLLMPolishingService: LLMPolishingServicing {
    func polish(
        request _: LLMPolishingRequest,
        configuration _: LLMPolishingConfiguration
    ) async throws -> LLMPolishingResult {
        throw LLMPolishingError.networkError("Connection refused")
    }
}

private struct MockPolishingError: Error {}

private final class MockAppConfigStore: AppConfigServing {
    private let replacementDictionary: ReplacementDictionary
    private let promptTemplates: LLMPromptTemplates
    private(set) var loadReplacementDictionaryCallCount = 0
    private(set) var loadLLMPromptTemplatesCallCount = 0

    init(
        replacementDictionary: ReplacementDictionary = ReplacementDictionary(entries: []),
        promptTemplates: LLMPromptTemplates = LLMPromptTemplates(
            systemContent: "system",
            userContent: "{{input_text}}"
        )
    ) {
        self.replacementDictionary = replacementDictionary
        self.promptTemplates = promptTemplates
    }

    func configDirectoryURL() -> URL {
        FileManager.default.temporaryDirectory
    }

    func loadReplacementDictionary() -> ReplacementDictionary {
        loadReplacementDictionaryCallCount += 1
        return replacementDictionary
    }

    func loadLLMPromptTemplates() -> LLMPromptTemplates {
        loadLLMPromptTemplatesCallCount += 1
        return promptTemplates
    }

    func loadTerminalAppBundleIDs() -> [String] {
        []
    }
}

private struct BufferCall {
    let displayText: String
    let commitText: String
}

@MainActor
private final class MockOverlayCoordinator: OverlayBufferSessionCoordinating {
    var commitOutcome: OverlayBufferCommitOutcome = .succeeded

    var startSessionAnchors: [OverlayAnchor?] = []
    var beginFinalizingCalls: [BufferCall] = []
    var refreshCalls: [BufferCall] = []
    var commitCallCount = 0
    var dismissAfterHoldCallCount = 0
    var lastDismissAfterHoldMinimumVisibility: TimeInterval?
    var resetCallCount = 0
    var captureLiveCommitTargetAppPIDCallCount = 0
    var commitTargetAppPID: pid_t? = nil
    var markPolishedCalls: [Bool] = []

    func resolveAnchorNow() -> OverlayAnchor {
        OverlayAnchor(
            targetRect: CGRect(x: 0, y: 0, width: 100, height: 24),
            source: .windowCenter
        )
    }

    func startSession(preResolvedAnchor: OverlayAnchor?) {
        startSessionAnchors.append(preResolvedAnchor)
    }

    func beginFinalizing(displayBufferText: String, commitBufferText: String) {
        beginFinalizingCalls.append(
            BufferCall(displayText: displayBufferText, commitText: commitBufferText)
        )
    }

    func refresh(displayBufferText: String, commitBufferText: String) {
        refreshCalls.append(
            BufferCall(displayText: displayBufferText, commitText: commitBufferText)
        )
    }

    func commitIfNeeded(
        using textCommitter: OverlayTextCommitting,
        autoCopyEnabled: Bool
    ) -> OverlayBufferCommitOutcome {
        commitCallCount += 1
        return commitOutcome
    }

    func dismissAfterHold(minimumVisibility: TimeInterval) {
        dismissAfterHoldCallCount += 1
        lastDismissAfterHoldMinimumVisibility = minimumVisibility
    }

    func reset() {
        resetCallCount += 1
    }

    func captureLiveCommitTargetAppPID() {
        captureLiveCommitTargetAppPIDCallCount += 1
    }

    func markPolished(_ polished: Bool) {
        markPolishedCalls.append(polished)
    }
}
