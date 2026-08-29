#if LOCALVOXTRAL_DOGFOOD

import ClaudeContextWire
import XCTest

@testable import localvoxtral

/// What the control socket says, and what it refuses to say.
///
/// No wall clock: the auto-stop and the probe deadline both run on an injected
/// `sleepFor`, so "the cap fired" is a decision this test makes, not something
/// it waits for.
@MainActor
final class DogfoodControlServiceTests: XCTestCase {
    /// Any test that reaches `beginDictationSession` arms the REAL 10s
    /// connect-timeout on a process-retained view model, and the alert it fires
    /// SIGTRAPs whatever test is running ten seconds later (AGENTS, PR #66).
    /// Every view model here therefore sets `isShowingConnectionFailureAlert`
    /// and is retained for the process lifetime.
    private static var retainedViewModels: [DictationViewModel] = []

    // MARK: - session start goes through the real trigger path

    func testSessionStartReportsARefusalRatherThanOverridingIt() async {
        let viewModel = makeViewModel()
        // Refused inside the same start path a real gesture takes — the socket
        // reports the refusal and does not route around it.
        viewModel.debugMicrophoneAuthorizationStatusOverride = .denied
        let service = makeService(viewModel: viewModel)

        let reply = await expectSuccess(service, .sessionStart(.overlayBuffer))

        XCTAssertEqual(reply["started"] as? Bool, false)
        XCTAssertEqual(reply["phase"] as? String, "idle")
        XCTAssertEqual(reply["outputMode"] as? String, "overlay_buffer")
        XCTAssertFalse(viewModel.isDictating)
        XCTAssertFalse(service.isAutoStopArmed, "a refused start must not arm the cap")
    }

    func testSessionStartReportsTheMicrophoneRefusalCategory() async {
        let viewModel = makeViewModel()
        viewModel.debugMicrophoneAuthorizationStatusOverride = .denied
        let service = makeService(viewModel: viewModel)

        let reply = await expectSuccess(service, .sessionStart(.liveAutoPaste))

        XCTAssertEqual(reply["started"] as? Bool, false)
        XCTAssertEqual(reply["outputMode"] as? String, "live_auto_paste")
        // Content-free categories only: the reply carries the token name, never
        // the user-facing sentence or the System Settings path in it.
        XCTAssertEqual(reply["errorToken"] as? String, "other")
        XCTAssertFalse(
            (reply["errorToken"] as? String ?? "").contains("System Settings"),
            "the reply must not carry user-facing copy"
        )
    }

    func testSessionStartRefusesWhileADictationIsAlreadyRunning() async {
        let viewModel = makeViewModel()
        viewModel.isDictating = true
        let service = makeService(viewModel: viewModel)

        let refusal = await expectFailure(service, .sessionStart(.overlayBuffer))

        XCTAssertEqual(refusal, .alreadyDictating)
        XCTAssertTrue(viewModel.isDictating, "a start must never toggle a running session off")
    }

    func testSessionStopRefusesWhenNothingIsRunningAndStillReleasesTheCap() async {
        let viewModel = makeViewModel()
        let service = makeService(viewModel: viewModel)

        let refusal = await expectFailure(service, .sessionStop)

        XCTAssertEqual(refusal, .notDictating)
        XCTAssertFalse(service.isAutoStopArmed)
    }

    func testSessionStopEndsARunningDictationThroughTheGesturePath() async {
        let viewModel = makeViewModel()
        viewModel.isDictating = true
        let service = makeService(viewModel: viewModel)

        let reply = await expectSuccess(service, .sessionStop)

        XCTAssertFalse(viewModel.isDictating)
        XCTAssertEqual(reply["stopped"] as? Bool, true)
        XCTAssertFalse(service.isAutoStopArmed)
    }

    // MARK: - the bounded session

    func testAnExplicitStopReleasesTheCap() async {
        let viewModel = makeViewModel()
        viewModel.isConnectingRealtimeSession = true
        let gate = SleepGate()
        let service = makeService(viewModel: viewModel, sleepFor: gate.sleep)

        _ = await service.execute(.sessionStart(.overlayBuffer))
        XCTAssertTrue(service.isAutoStopArmed)

        viewModel.isConnectingRealtimeSession = false
        viewModel.isDictating = true
        _ = await service.execute(.sessionStop)

        XCTAssertFalse(service.isAutoStopArmed, "a stopped session must not stay inside a cap")
    }

    func testTheCapStopsASessionThatOutlivedIt() async {
        let viewModel = makeViewModel()
        viewModel.isConnectingRealtimeSession = true
        let gate = SleepGate()
        let service = makeService(viewModel: viewModel, sleepFor: gate.sleep)

        let reply = await expectSuccess(service, .sessionStart(.overlayBuffer))
        XCTAssertEqual(reply["phase"] as? String, "connecting")
        XCTAssertTrue(service.isAutoStopArmed, "a session on its way up is inside the cap")
        XCTAssertEqual(reply["autoStopSeconds"] as? Int, 7)

        // The client is gone; the cap's window expires.
        viewModel.isConnectingRealtimeSession = false
        viewModel.isDictating = true
        gate.release()
        await gate.waitForSleepToReturn()
        await Task.yield()
        await Task.yield()

        XCTAssertFalse(viewModel.isDictating, "the cap must end a session the client abandoned")
    }

    func testShutdownReleasesTheCapSoAQuitDoesNotLeaveItWaiting() async {
        let viewModel = makeViewModel()
        viewModel.isConnectingRealtimeSession = true
        let gate = SleepGate()
        let service = makeService(viewModel: viewModel, sleepFor: gate.sleep)

        _ = await service.execute(.sessionStart(.overlayBuffer))
        XCTAssertTrue(service.isAutoStopArmed)

        service.shutdown()

        XCTAssertFalse(service.isAutoStopArmed)
    }

    // MARK: - registry list

    /// The verb exists to tell "no sessions registered" apart from "surface
    /// resolution failed" — the ambiguity that is the common dead end here.
    func testRegistryListDistinguishesAnEmptyRegistryFromAPopulatedOne() async {
        let empty = makeService(viewModel: makeViewModel(), sessions: [])
        let emptyReply = await expectSuccess(empty, .registryList)
        XCTAssertEqual(emptyReply["count"] as? Int, 0)
        XCTAssertEqual((emptyReply["sessions"] as? [Any])?.count, 0)

        let populated = makeService(viewModel: makeViewModel(), sessions: [Self.localSnapshot()])
        let reply = await expectSuccess(populated, .registryList)
        XCTAssertEqual(reply["count"] as? Int, 1)
        let row = ((reply["sessions"] as? [[String: Any]]) ?? []).first
        XCTAssertEqual(row?["origin"] as? String, "local")
        XCTAssertEqual(row?["agent"] as? String, "claude")
        XCTAssertEqual(row?["hasTTY"] as? Bool, true)
        XCTAssertEqual(row?["hasHerdrPane"] as? Bool, true)
        XCTAssertEqual(row?["workspaceIsLocal"] as? Bool, true)
    }

    /// Field by field: the registry holds a marker, a workspace path, a tty, a
    /// pane id, a socket path and a session id, and NONE of them may cross.
    func testRegistryListNamesNothingThatIdentifiesASession() async {
        let service = makeService(viewModel: makeViewModel(), sessions: [Self.localSnapshot()])
        let raw = await expectSuccessRaw(service, .registryList)

        for secret in [
            Self.sessionID,
            Self.markerValue,
            Self.workspacePath,
            Self.ttyPath,
            Self.paneID,
            Self.herdrSocketPath,
            Self.bridgeSessionID,
        ] {
            XCTAssertFalse(raw.contains(secret), "registry list leaked \(secret)")
        }
    }

    // MARK: - join report

    func testJoinReportIsEmptyBeforeAnyDictationResolvedOne() async {
        DogfoodCaptureTap.shared.noteResolvedJoin(
            ClaudeSessionJoinSummary.summarize(join: nil, abstentions: [])
        )
        let service = makeService(viewModel: makeViewModel())
        let reply = await expectSuccess(service, .joinReport)

        XCTAssertEqual(reply["present"] as? Bool, true)
        let join = reply["join"] as? [String: Any]
        XCTAssertEqual(join?["arm"] as? String, "none")
    }

    /// `join report` reads the tap's DURABLE slot. Reading the consumable one
    /// would steal the abstention chain from the capture record that is about
    /// to be written for the same dictation.
    func testJoinReportDoesNotConsumeTheCaptureRecordsAbstentions() async {
        DogfoodCaptureTap.shared.beginSession()
        DogfoodCaptureTap.shared.noteJoinAbstention("tty: stale")
        DogfoodCaptureTap.shared.noteResolvedJoin(
            ClaudeSessionJoinSummary.summarize(join: nil, abstentions: ["tty: stale"])
        )
        let service = makeService(viewModel: makeViewModel())

        _ = await expectSuccess(service, .joinReport)
        _ = await expectSuccess(service, .joinReport)

        XCTAssertEqual(
            DogfoodCaptureTap.shared.consumeJoinAbstentions(), ["tty: stale"],
            "the record's causes must survive being reported on"
        )
    }

    func testJoinReportUsesTheSharedSummaryVocabulary() async {
        DogfoodCaptureTap.shared.noteResolvedJoin(
            ClaudeSessionJoinSummary(
                arm: "herdrPane",
                abstentionReason: "tty: no answer",
                origin: "local",
                terminal: "Ghostty",
                herdrBound: true,
                workspaceIsLocal: true
            )
        )
        let service = makeService(viewModel: makeViewModel())
        let reply = await expectSuccess(service, .joinReport)
        let join = reply["join"] as? [String: Any]

        XCTAssertEqual(join?["arm"] as? String, "herdrPane")
        XCTAssertEqual(join?["terminal"] as? String, "Ghostty")
        XCTAssertEqual(join?["herdrBound"] as? Bool, true)
        // The keys are the summary's, not a second naming of them.
        XCTAssertEqual(
            Set((join ?? [:]).keys),
            ["arm", "abstentionReason", "origin", "terminal", "herdrBound", "workspaceIsLocal"]
        )
    }

    // MARK: - surface probe

    func testSurfaceProbeRefusesWhileADictationIsResolvingItsOwnJoin() async {
        let viewModel = makeViewModel()
        viewModel.isDictating = true
        let service = makeService(viewModel: viewModel)

        let refusal = await expectFailure(service, .surfaceProbe)
        XCTAssertEqual(refusal, .dictationInProgress)
    }

    func testSurfaceProbeReportsTheRegistryItResolvedAgainst() async {
        let service = makeService(
            viewModel: makeViewModel(),
            sessions: [Self.localSnapshot()],
            accessibilityTrusted: false
        )
        let reply = await expectSuccess(service, .surfaceProbe)

        XCTAssertEqual(reply["registrySessions"] as? Int, 1)
        let join = reply["join"] as? [String: Any]
        XCTAssertEqual(join?["arm"] as? String, "none")
        XCTAssertEqual(
            join?["abstentionReason"] as? String,
            "probe: accessibility permission not granted"
        )
    }

    /// The probe is bounded by ABANDONMENT: a resolver that never returns must
    /// not hold the socket, and the deadline task must not be waiting on it.
    func testSurfaceProbeIsBoundedWhenTheResolverNeverAnswers() async {
        let service = makeService(
            viewModel: makeViewModel(),
            accessibilityTrusted: true,
            frontmostTarget: TerminalScreenTarget(pid: 42, bundleID: "com.mitchellh.ghostty"),
            resolveSurface: { _ in
                await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
                return nil
            },
            sleepFor: { _ in }
        )

        let refusal = await expectFailure(service, .surfaceProbe)
        XCTAssertEqual(refusal, .probeTimedOut)
    }

    // MARK: - Fixtures

    private static let sessionID = "11111111-2222-3333-4444-555555555555"
    private static let markerValue = "lvx-marker-abcdef0123456789"
    private static let workspacePath = "/Users/owner/work/secret-project"
    private static let ttyPath = "/dev/ttys004"
    private static let paneID = "pane-9f3c2a"
    private static let herdrSocketPath = "/Users/owner/.local/run/herdr/default.sock"
    private static let bridgeSessionID = "session_abc123def456"

    private static func localSnapshot() -> ClaudeSessionSnapshot {
        var snapshot = ClaudeSessionSnapshot(
            sessionID: sessionID,
            origin: .localAuthenticated(peerUID: 501),
            marker: ClaudeSessionMarker(value: markerValue),
            firstSeen: Date(timeIntervalSince1970: 1_000)
        )
        snapshot.workspace = ClaudeWorkspaceReference.make(
            rawCwd: workspacePath,
            origin: .localAuthenticated(peerUID: 501)
        )
        snapshot.latestPriorUserPrompt = "please refactor the resolver"
        snapshot.process = ClaudeHookProcessInfo(
            hookPID: 10,
            claudePID: 11,
            tty: ttyPath,
            termProgram: "ghostty",
            herdrPaneID: paneID,
            herdrSocketPath: herdrSocketPath,
            bridgeSessionID: bridgeSessionID
        )
        return snapshot
    }

    private func makeViewModel() -> DictationViewModel {
        let suiteName = "localvoxtral.DogfoodControlServiceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }

        let settings = SettingsStore(defaults: defaults, environment: [:])
        let viewModel = DictationViewModel(settings: settings, startRuntimeServices: false)
        viewModel.isShowingConnectionFailureAlert = true
        Self.retainedViewModels.append(viewModel)
        return viewModel
    }

    private func makeService(
        viewModel: DictationViewModel,
        sessions: [ClaudeSessionSnapshot] = [],
        accessibilityTrusted: Bool = false,
        frontmostTarget: TerminalScreenTarget? = nil,
        resolveSurface: @escaping @MainActor (TerminalScreenTarget) async -> ClaudeSessionJoin? = { _ in nil },
        sleepFor: @escaping DogfoodControlService.SleepClosure = { _ in }
    ) -> DogfoodControlService {
        DogfoodControlService(
            viewModel: viewModel,
            liveSessions: { sessions },
            hasLiveSessions: { !sessions.isEmpty },
            accessibilityTrusted: { accessibilityTrusted },
            frontmostTarget: { frontmostTarget },
            resolveSurface: resolveSurface,
            sleepFor: sleepFor,
            autoStopAfter: .seconds(7)
        )
    }

    private func expectSuccessRaw(
        _ service: DogfoodControlService,
        _ command: DogfoodControlProtocol.Command,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async -> String {
        switch await service.execute(command) {
        case .success(let body): return body
        case .failure(let refusal):
            XCTFail("expected success, got \(refusal)", file: file, line: line)
            return "{}"
        }
    }

    private func expectSuccess(
        _ service: DogfoodControlService,
        _ command: DogfoodControlProtocol.Command,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async -> [String: Any] {
        let body = await expectSuccessRaw(service, command, file: file, line: line)
        guard let object = try? JSONSerialization.jsonObject(with: Data(body.utf8))
            as? [String: Any]
        else {
            XCTFail("result was not a JSON object: \(body)", file: file, line: line)
            return [:]
        }
        return object
    }

    private func expectFailure(
        _ service: DogfoodControlService,
        _ command: DogfoodControlProtocol.Command,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async -> DogfoodControlService.Refusal? {
        switch await service.execute(command) {
        case .success(let body):
            XCTFail("expected a refusal, got \(body)", file: file, line: line)
            return nil
        case .failure(let refusal):
            return refusal
        }
    }
}

/// An injected clock the test opens by hand — no wall clock, no polling.
private final class SleepGate: @unchecked Sendable {
    private let started = DispatchSemaphore(value: 0)
    private let allowed = DispatchSemaphore(value: 0)
    private let returned = DispatchSemaphore(value: 0)

    var sleep: DogfoodControlService.SleepClosure {
        { [self] _ in
            started.signal()
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.global().async {
                    self.allowed.wait()
                    continuation.resume()
                }
            }
            returned.signal()
        }
    }

    func release() {
        allowed.signal()
    }

    func waitForSleepToReturn() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                self.returned.wait()
                continuation.resume()
            }
        }
    }
}

#endif
