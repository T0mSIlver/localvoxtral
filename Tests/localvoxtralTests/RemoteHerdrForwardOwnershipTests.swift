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

    func testAJoinWithNoTunnelIsNotRetained() async {
        let viewModel = makeViewModel()
        viewModel.context.retainRemoteHerdrForward(of: nil)
        XCTAssertEqual(viewModel.context.openRemoteHerdrForwardCount, 0)
    }
}
