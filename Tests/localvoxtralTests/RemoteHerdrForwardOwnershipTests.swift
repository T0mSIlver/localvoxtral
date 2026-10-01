import Foundation
import XCTest
@testable import localvoxtral
import localvoxtralTestSupport

/// Who owns a remote herdr join's ssh forward once the view model holds the
/// join. The resolver side of the arm is RemoteHerdrJoinTests, in the core.
@MainActor
final class RemoteHerdrForwardOwnershipTests: XCTestCase, RemoteHerdrJoinFixture {
    // MARK: Forward ownership (review finding 4)

    /// A resolved remote herdr join, with the fake forwards that produced it.
    private func makeJoinWithForward() async throws -> (ClaudeSessionJoin, RecordingForwards) {
        let registry = makeRegistry()
        ingestRemoteHerdrSession(into: registry)
        let forwards = RecordingForwards()
        let join = try unwrapAsync(
            await resolver(
                registry: registry,
                panes: RemoteJoinHerdrPanes(focused: focusedPane()),
                forwards: forwards
            ).resolve(target: ghostty)
        )
        return (join, forwards)
    }

    private func makeViewModel() -> DictationViewModel {
        let suiteName = "localvoxtral.RemoteHerdrJoinTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        let settings = SettingsStore(defaults: defaults, environment: [:], secretStore: InMemorySecretStore())
        let viewModel = DictationViewModel(settings: settings, startRuntimeServices: false)
        retainForTestProcessLifetime(viewModel)
        return viewModel
    }

    func testAnAbortedConnectClosesTheTunnel() async throws {
        // The abort path never reaches stopped-session cleanup, so before this
        // the ssh child stayed up for the rest of the app's life.
        let (join, forwards) = try await makeJoinWithForward()
        let viewModel = makeViewModel()
        viewModel.context.claudeSessionJoin = join
        viewModel.context.retainRemoteHerdrForward(of: join)
        XCTAssertEqual(viewModel.context.openRemoteHerdrForwardCount, 1)

        viewModel.session.abortConnectingSession()

        XCTAssertEqual(forwards.closeCount, 1)
        XCTAssertEqual(forwards.process.terminations.withLock { $0 }, 1)
        XCTAssertEqual(viewModel.context.openRemoteHerdrForwardCount, 0)
    }

    func testDiscardingTheStartCaptureClosesTheTunnel() async throws {
        let (join, forwards) = try await makeJoinWithForward()
        let viewModel = makeViewModel()
        viewModel.context.claudeSessionJoin = join
        viewModel.context.retainRemoteHerdrForward(of: join)

        viewModel.context.discardTerminalScreenCapture()

        XCTAssertNil(viewModel.context.claudeSessionJoin)
        XCTAssertEqual(forwards.closeCount, 1)
    }

    func testTheTunnelIsStillOwnedAfterTheCommitPathConsumesTheJoin() async throws {
        // The quit-during-polish hole: the commit path takes the join, so an
        // owner that reached the child through `claudeSessionJoin` found nil
        // and the ssh survived app exit.
        let (join, forwards) = try await makeJoinWithForward()
        let viewModel = makeViewModel()
        viewModel.context.claudeSessionJoin = join
        viewModel.context.retainRemoteHerdrForward(of: join)

        let consumed = viewModel.context.consumeClaudeSessionJoin()
        XCTAssertNotNil(consumed)
        XCTAssertNil(viewModel.context.claudeSessionJoin)
        XCTAssertEqual(forwards.closeCount, 0, "the stop-side pane read still needs it")

        // What `applicationWillTerminate` now does.
        viewModel.context.closeRemoteHerdrForwards()

        XCTAssertEqual(forwards.closeCount, 1)
    }

    func testClosingTunnelsIsIdempotentAndSurvivesHavingNone() async throws {
        let (join, forwards) = try await makeJoinWithForward()
        let viewModel = makeViewModel()
        viewModel.context.retainRemoteHerdrForward(of: join)

        viewModel.context.closeRemoteHerdrForwards()
        viewModel.context.closeRemoteHerdrForwards()
        viewModel.context.discardTerminalScreenCapture()

        XCTAssertEqual(forwards.closeCount, 1)
        XCTAssertEqual(forwards.process.terminations.withLock { $0 }, 1)
    }

    func testClosingAPanelAuthorizedJoinClearsItsTokenAndClosesItsForward() async throws {
        let registry = makeRegistry()
        ingestRemoteHerdrSession(into: registry)
        let panes = RemoteJoinHerdrPanes(focused: focusedPane())
        let forwards = RecordingForwards()
        let token = HerdrPanelBindingProbe.token(randomBits: 31)
        let (ticks, tickContinuation) = AsyncStream.makeStream(of: Void.self)
        let join = try unwrapAsync(await resolver(
            registry: registry,
            panes: panes,
            forwards: forwards,
            panelMetadata: panes,
            panelGrid: token,
            panelRandomBits: 31,
            indicatorSleepFor: { _ in
                var iterator = ticks.makeAsyncIterator()
                _ = await iterator.next()
            }
        ).resolve(target: ghostty))
        let indicator = try XCTUnwrap(join.remoteHerdrIndicator)
        let viewModel = makeViewModel()

        viewModel.context.retainRemoteHerdrForward(of: join)
        XCTAssertEqual(viewModel.context.openRemoteHerdrForwardCount, 1)
        XCTAssertEqual(
            viewModel.context.liveRemoteHerdrIndicators,
            [indicator],
            "the view model must retain the indicator owner, not only its raw forward"
        )
        viewModel.context.closeRemoteHerdrForwards()
        await indicator.stopAndWait()
        tickContinuation.finish()

        XCTAssertEqual(viewModel.context.openRemoteHerdrForwardCount, 0)
        XCTAssertTrue(
            panes.panelReports.withLock { $0 }.contains {
                $0.socketPath == forwards.localSocketPath
                    && $0.paneID == remotePaneID
                    && $0.value == nil
                    && $0.ttl == nil
            },
            "view-model teardown must explicitly clear the retained panel token"
        )
        XCTAssertEqual(forwards.closeCount, 1)
        XCTAssertEqual(forwards.process.terminations.withLock { $0 }, 1)
    }

    /// #1112: a commit cancelled while its stop-side pane read is in flight
    /// resumes after the next dictation has taken its own lease. It must
    /// release only its own, never the next dictation's indicator and forward.
    func testACancelledCommitLeavesTheNextDictationsLeaseAlone() async throws {
        // Dictation A: a remote herdr join whose stop-side pane read is held.
        let (readEntered, readEnteredContinuation) = AsyncStream.makeStream(of: Void.self)
        let (readRelease, readReleaseContinuation) = AsyncStream.makeStream(of: Void.self)
        let registryA = makeRegistry()
        ingestRemoteHerdrSession(into: registryA)
        let panesA = RemoteJoinHerdrPanes(
            focused: focusedPane(),
            texts: ["stop text"],
            paneReadGate: {
                readEnteredContinuation.yield()
                var iterator = readRelease.makeAsyncIterator()
                _ = await iterator.next()
            }
        )
        let forwardsA = RecordingForwards()
        let resolverA = resolver(registry: registryA, panes: panesA, forwards: forwardsA)
        let joinA = try unwrapAsync(await resolverA.resolve(target: ghostty))
        let paneKeyA = try XCTUnwrap(joinA.socketPaneKey)

        // Dictation B: a panel-authorized join, so it owns a mic indicator.
        let registryB = makeRegistry()
        ingestRemoteHerdrSession(into: registryB)
        let panesB = RemoteJoinHerdrPanes(focused: focusedPane())
        let forwardsB = RecordingForwards()
        let token = HerdrPanelBindingProbe.token(randomBits: 31)
        let (ticks, tickContinuation) = AsyncStream.makeStream(of: Void.self)
        let joinB = try unwrapAsync(await resolver(
            registry: registryB,
            panes: panesB,
            forwards: forwardsB,
            panelMetadata: panesB,
            panelGrid: token,
            panelRandomBits: 31,
            indicatorSleepFor: { _ in
                var iterator = ticks.makeAsyncIterator()
                _ = await iterator.next()
            }
        ).resolve(target: ghostty))
        let indicatorB = try XCTUnwrap(joinB.remoteHerdrIndicator)

        let viewModel = makeViewModel()
        viewModel.settings.terminalScreenContextEnabled = true
        viewModel.textInsertion.debugSetAccessibilityTrusted(true)
        viewModel.context.claudeSessionJoinResolver = resolverA
        viewModel.context.retainRemoteHerdrForward(of: joinA)

        let endpointURL = try XCTUnwrap(URL(string: "http://127.0.0.1:8080/v1/chat/completions"))
        let commitA = Task { @MainActor in
            await PolishContextGatherer.gather(PolishContextGatherer.Input(
                settings: viewModel.settings,
                textInsertion: viewModel.textInsertion,
                context: viewModel.context,
                repoVocabularyGrounding: FakeRepoVocabularyGrounding(outcome: nil),
                learnedTermStore: nil,
                endpointURL: endpointURL,
                workingText: "hello",
                capturedScreenDecision: .drop(reason: .noStartCapture),
                capturedSocketPaneStart: SocketPaneScreenCapture(text: "start text", paneKey: paneKeyA),
                capturedClaudeJoin: joinA,
                capturedClipboardContext: nil,
                templateCarriesDictionarySlot: false,
                needsRepoGroundingForConflictSafety: false
            ))
        }
        var entered = readEntered.makeAsyncIterator()
        _ = await entered.next()

        // A new dictation cancels A (its cleanup releases A's lease), then B
        // takes its own lease, all while A's pane read is still out.
        commitA.cancel()
        viewModel.context.discardTerminalScreenCapture()
        XCTAssertEqual(forwardsA.closeCount, 1)
        viewModel.context.retainRemoteHerdrForward(of: joinB)

        readReleaseContinuation.yield()
        let material = await commitA.value

        XCTAssertNil(material, "a cancelled commit stops at the checkpoint after the pane read")
        XCTAssertEqual(
            viewModel.context.liveRemoteHerdrIndicators,
            [indicatorB],
            "the cancelled commit must not stop the next dictation's indicator"
        )
        XCTAssertEqual(viewModel.context.openRemoteHerdrForwardCount, 1)
        XCTAssertFalse(
            panesB.panelReports.withLock { $0 }.contains { $0.value == nil },
            "B's panel token must not be cleared"
        )
        XCTAssertEqual(forwardsB.closeCount, 0, "B's forward stays leased")

        viewModel.context.closeRemoteHerdrForwards()
        await indicatorB.stopAndWait()
        tickContinuation.finish()
        XCTAssertEqual(forwardsB.closeCount, 1)
    }

    func testAJoinWithNoTunnelIsNotRetained() async {
        let viewModel = makeViewModel()
        viewModel.context.retainRemoteHerdrForward(of: nil)
        XCTAssertEqual(viewModel.context.openRemoteHerdrForwardCount, 0)
    }
}
