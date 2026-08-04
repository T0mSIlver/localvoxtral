import Foundation
import Synchronization
import XCTest
@testable import localvoxtral

#if canImport(Darwin)
import Darwin
#endif

/// Records what the pane asked for, and fails on demand. No `claude` process is
/// ever spawned — which is the point: the build host HAS Claude Code installed,
/// so "reports when the CLI is missing" is untestable against the real thing.
private final class StubPluginService: ClaudePluginInstalling {
    private let calls = Mutex<[String]>([])
    // Typed, not `any Error`: an existential is not Sendable, and this stub has
    // to cross into the model's @Sendable action closure.
    private let failure = Mutex<ClaudePluginInstallService.ServiceError?>(nil)

    init(failWith error: ClaudePluginInstallService.ServiceError? = nil) {
        failure.withLock { $0 = error }
    }

    var recordedCalls: [String] { calls.withLock { $0 } }

    private func record(_ name: String) throws {
        calls.withLock { $0.append(name) }
        if let error = failure.withLock({ $0 }) { throw error }
    }

    func installPlugin() throws { try record("install") }
    func updatePlugin() throws { try record("update") }
    func uninstallPlugin() throws { try record("uninstall") }
}

/// A listener that binds nothing.
///
/// Unit tests must not open 8473: it would conflict with the developer's own
/// running app and with any other test in the same process. This stub is what
/// makes "the port follows enrollment" assertable at all.
@MainActor
private final class StubListener: ClaudeRemoteListenerControlling {
    private let hosts: ClaudeRemoteHostRegistry
    var isListening = false
    var boundPort: UInt16 = 8473
    var reconcileCount = 0
    /// Thrown on the next reconcile that would bind.
    var bindError: (any Error)?
    /// What the real listener would have counted. Set by a test to stand in for
    /// a night of rejected connections.
    var rejectionSnapshot = ClaudeRemoteRejectionTally.Snapshot()

    /// Shared with the forward stubs so a test can assert the ORDER of the two
    /// shutdowns, not just that both happened.
    var journal: ShutdownJournal?

    init(hosts: ClaudeRemoteHostRegistry) {
        self.hosts = hosts
    }

    func reconcile() throws {
        reconcileCount += 1
        if isListening, !hosts.hasActiveHosts { journal?.note("listener.stop") }
        if hosts.hasActiveHosts {
            guard !isListening else { return }
            if let bindError { throw bindError }
            isListening = true
        } else {
            isListening = false
        }
    }
}

private final class MemoryStore: ClaudeRemoteHostStoreIO {
    private let contents = Mutex<[String: Data]>([:])
    func read(from url: URL) throws -> Data? { contents.withLock { $0[url.path] } }
    func write(_ data: Data, to url: URL) throws { contents.withLock { $0[url.path] = data } }
}

private final class RecordingSSHConfigFileSystem: ClaudeRemoteSSHConfigFileSystem {
    private let reads = Mutex(0)
    private let writes = Mutex(0)
    private let config = Mutex<String?>(nil)
    private let written = Mutex<String?>(nil)
    /// Stands in for the one state the service refuses to write through: a
    /// symlinked ~/.ssh/config, where a rename would replace the link.
    private let symlinked = Mutex(false)

    var readCount: Int { reads.withLock { $0 } }
    var writeCount: Int { writes.withLock { $0 } }
    var lastWrittenText: String? { written.withLock { $0 } }

    func setConfig(_ text: String) { config.withLock { $0 = text } }
    func setSymlinked(_ value: Bool) { symlinked.withLock { $0 = value } }

    func readState() throws -> ClaudeRemoteSSHConfigState {
        reads.withLock { $0 += 1 }
        return ClaudeRemoteSSHConfigState(
            directoryExists: true,
            configData: config.withLock { $0 }.map { Data($0.utf8) },
            configPermissions: nil,
            configIsSymlink: symlinked.withLock { $0 }
        )
    }

    func createSSHDirectory(permissions _: UInt16) throws {}

    func atomicWriteConfig(_ data: Data, permissions: UInt16) throws {
        XCTAssertFalse(data.isEmpty)
        XCTAssertEqual(permissions, 0o600)
        writes.withLock { $0 += 1 }
        let text = String(decoding: data, as: UTF8.self)
        written.withLock { $0 = text }
        config.withLock { $0 = text }
    }
}

/// A forward that records instead of spawning ssh. The model's contract is
/// "persist the flag, then reconcile, then re-render the rows"; whether ssh
/// reconnects is the supervisor's suite.
@MainActor
/// Ordered record of the two shutdowns, so "forwards first, listener second"
/// is asserted as a SEQUENCE. Both happening is not the property — the whole
/// failure is a hook arriving in the window between them.
final class ShutdownJournal: @unchecked Sendable {
    private let entries = Mutex<[String]>([])
    func note(_ entry: String) { entries.withLock { $0.append(entry) } }
    var recorded: [String] { entries.withLock { $0 } }
}

private final class StubForwarding: ClaudeRemoteForwarding {
    var journal: ShutdownJournal?
    var state: ClaudeRemoteForwardSupervisor.State = .stopped
    var onStateChange: (@MainActor (ClaudeRemoteForwardSupervisor.State) -> Void)?
    /// Settable so a test can hand the coordinator a teardown that is
    /// still draining and prove the replacement waits for it.
    var teardown: Task<Void, Never>?
    private(set) var retried = 0

    func start() { transition(to: .connecting) }
    func stop() {
        journal?.note("forward.stop")
        transition(to: .stopped)
    }
    func retry() { retried += 1 }

    func transition(to newState: ClaudeRemoteForwardSupervisor.State) {
        state = newState
        onStateChange?(newState)
    }
}

@MainActor
final class ClaudeIntegrationSettingsModelTests: XCTestCase {
    private func makeRegistry() throws -> ClaudeRemoteHostRegistry {
        try ClaudeRemoteHostRegistry(
            fileURL: URL(fileURLWithPath: "/tmp/lvx-settings-test/hosts.json"),
            io: MemoryStore(),
            now: { Date(timeIntervalSince1970: 1_000_000) }
        )
    }

    private func makeModel(
        registry: ClaudeRemoteHostRegistry?,
        listener: (any ClaudeRemoteListenerControlling)?,
        plugin: StubPluginService = StubPluginService(),
        enrollmentService: ClaudeRemoteEnrollmentService = ClaudeRemoteEnrollmentService(),
        // Frozen by default (AGENTS: no wall-clock in tests). The registry's
        // own clock is pinned to the same instant, so a host that just reported
        // reads as "just now" rather than as whatever the machine's clock did.
        now: @escaping @Sendable () -> Date = { Date(timeIntervalSince1970: 1_000_000) },
        // Pinned, never derived here: the model must use what it is handed, and
        // a test that computed the allocation would only prove the derivation
        // twice.
        remoteForwardPort: UInt16 = ClaudeRemoteForwardPort.legacyPort,
        forwards: ClaudeRemoteForwardCoordinator? = nil
    ) -> ClaudeIntegrationSettingsModel {
        ClaudeIntegrationSettingsModel(
            registry: registry,
            listener: listener,
            pluginService: { plugin },
            enrollmentService: enrollmentService,
            // Synchronous: the production default hops to a detached task, which
            // would make every assertion below a race. The seam exists for
            // exactly this.
            performAsync: { body in
                do {
                    try body()
                    return nil
                } catch {
                    return ClaudePluginActionFailure(error)
                }
            },
            performEnrollmentAsync: { body in
                do {
                    return ClaudeEnrollmentActionAttempt(steps: try body(), failure: nil)
                } catch {
                    return ClaudeEnrollmentActionAttempt(
                        steps: [],
                        failure: ClaudeEnrollmentActionFailure(error)
                    )
                }
            },
            now: now,
            remoteForwardPort: remoteForwardPort,
            forwards: forwards
        )
    }

    // MARK: Persistent forward toggle

    /// Holds the stub forwards so a test can drive their state.
    private final class ForwardStubs: @unchecked Sendable {
        var byHost: [String: StubForwarding] = [:]
        var journal: ShutdownJournal?
    }

    private func makeForwardCoordinator(
        registry: ClaudeRemoteHostRegistry,
        stubs: ForwardStubs,
        isListenerBound: @escaping @MainActor () -> Bool = { true }
    ) -> ClaudeRemoteForwardCoordinator {
        ClaudeRemoteForwardCoordinator(
            hosts: registry,
            remoteForwardPort: 28542,
            listenerPort: 8473,
            isListenerBound: isListenerBound,
            makeSupervisor: { configuration in
                let stub = StubForwarding()
                stub.journal = stubs.journal
                stubs.byHost[configuration.hostID] = stub
                return stub
            }
        )
    }

    func testEnablingTheTunnelPersistsTheFlagAndStartsTheForward() async throws {
        let registry = try makeRegistry()
        let stubs = ForwardStubs()
        let forwards = makeForwardCoordinator(registry: registry, stubs: stubs)
        let model = makeModel(
            registry: registry,
            listener: StubListener(hosts: registry),
            remoteForwardPort: 28542,
            forwards: forwards
        )
        model.enrollLabel = "buildhost"
        model.enrollSSHAlias = "builder"
        await model.enroll()
        model.dismissPlan()
        let hostID = try XCTUnwrap(model.hosts.first).id

        // Off by default: the app must never ssh anywhere unasked.
        XCTAssertFalse(try XCTUnwrap(model.hosts.first).persistentForwardEnabled)
        XCTAssertTrue(stubs.byHost.isEmpty)

        model.setPersistentForward(true, hostID: hostID)

        XCTAssertTrue(try XCTUnwrap(registry.host(id: hostID)).persistentForwardEnabled)
        XCTAssertTrue(try XCTUnwrap(model.hosts.first).persistentForwardEnabled)
        XCTAssertNotNil(stubs.byHost[hostID], "the flag alone is not a tunnel")
        XCTAssertTrue(try XCTUnwrap(model.hosts.first).canHoldForward)

        model.setPersistentForward(false, hostID: hostID)
        XCTAssertFalse(try XCTUnwrap(registry.host(id: hostID)).persistentForwardEnabled)
        XCTAssertNil(model.hosts.first?.forwardStatusText, "a stopped forward has nothing to report")
    }

    func testAFailedForwardShowsOneShortSentenceAndOffersRetry() async throws {
        let registry = try makeRegistry()
        let stubs = ForwardStubs()
        let forwards = makeForwardCoordinator(registry: registry, stubs: stubs)
        let model = makeModel(
            registry: registry,
            listener: StubListener(hosts: registry),
            remoteForwardPort: 28542,
            forwards: forwards
        )
        model.enrollLabel = "buildhost"
        model.enrollSSHAlias = "builder"
        await model.enroll()
        model.dismissPlan()
        let hostID = try XCTUnwrap(model.hosts.first).id
        model.setPersistentForward(true, hostID: hostID)

        // NO refreshHosts() here, deliberately. The manual call is what used to
        // make this pass: the pane renders copies of these rows and only
        // rebuilt them on an explicit action or on appear, so in the running
        // app every transition after the first "Connecting…" snapshot —
        // forwarding, retrying, portUnavailable — reached the coordinator's
        // dictionary and stopped there. The user watched a tunnel that had
        // already failed claim it was still connecting.
        try XCTUnwrap(stubs.byHost[hostID]).transition(to: .portUnavailable)

        let row = try XCTUnwrap(model.hosts.first)
        XCTAssertEqual(row.forwardStatusText, "Port held — close ssh sessions to that host.")
        XCTAssertTrue(row.forwardIsFailure)
        // Owner rule: a Settings status line is one short sentence; the ssh
        // stderr tail belongs in the log.
        XCTAssertLessThan(try XCTUnwrap(row.forwardStatusText).count, 60)

        model.retryPersistentForward(hostID: hostID)
        XCTAssertEqual(try XCTUnwrap(stubs.byHost[hostID]).retried, 1)
    }

    func testRevokingTheLastHostStopsTheForwardBeforeClosingTheListener() async throws {
        // Startup order is listener-then-forwards, and shutdown is documented
        // as its mirror — but revoke ran `listener.reconcile()` (which closes
        // the port) and only then reconciled the forwards. In that window the
        // tunnel is still up and its destination is already gone, so a hook
        // arriving from the remote host gets connection-refused THROUGH a live
        // forward, and the Mac's ssh client prints `connect_to … failed.` into
        // the user's remote terminal.
        let registry = try makeRegistry()
        let journal = ShutdownJournal()
        let stubs = ForwardStubs()
        stubs.journal = journal
        let listener = StubListener(hosts: registry)
        listener.journal = journal
        let forwards = makeForwardCoordinator(registry: registry, stubs: stubs)
        let model = makeModel(
            registry: registry,
            listener: listener,
            remoteForwardPort: 28542,
            forwards: forwards
        )
        model.enrollLabel = "buildhost"
        model.enrollSSHAlias = "builder"
        await model.enroll()
        model.dismissPlan()
        let hostID = try XCTUnwrap(model.hosts.first).id
        model.setPersistentForward(true, hostID: hostID)
        XCTAssertTrue(listener.isListening)

        await model.revoke(hostID: hostID)

        XCTAssertEqual(
            journal.recorded, ["forward.stop", "listener.stop"],
            "shutdown is the mirror of startup: forwards first, listener second"
        )
        XCTAssertFalse(listener.isListening)
    }

    func testAHostWithNoAliasIsNotOfferedATunnel() async throws {
        let registry = try makeRegistry()
        let stubs = ForwardStubs()
        let forwards = makeForwardCoordinator(registry: registry, stubs: stubs)
        let enrollment = try registry.enroll(label: "buildhost")
        let model = makeModel(
            registry: registry,
            listener: StubListener(hosts: registry),
            remoteForwardPort: 28542,
            forwards: forwards
        )

        XCTAssertEqual(model.hosts.first?.id, enrollment.host.id)
        XCTAssertFalse(
            try XCTUnwrap(model.hosts.first).canHoldForward,
            "we were never told where to ssh, and the label is not a substitute"
        )
    }

    func testNoTunnelIsOfferedWhenTheAppHasNoForwardCoordinator() async throws {
        let registry = try makeRegistry()
        let model = makeModel(registry: registry, listener: StubListener(hosts: registry))
        _ = try registry.enroll(label: "buildhost", sshHostAlias: "builder")
        model.refreshHosts()
        XCTAssertFalse(try XCTUnwrap(model.hosts.first).canHoldForward)
    }

    // MARK: Local plugin

    func testInstallOrUpdateRunsTheUpdatePathAndReportsShortSuccess() async {
        let plugin = StubPluginService()
        let model = makeModel(registry: nil, listener: nil, plugin: plugin)
        await model.updatePlugin()
        XCTAssertEqual(plugin.recordedCalls, ["update"])
        XCTAssertEqual(model.pluginResult, "Updated.")
        XCTAssertNil(model.alert, "a success must not raise an alert")
    }

    func testAMissingCLIIsAShortLineInThePaneAndLongDetailInTheAlert() async {
        let plugin = StubPluginService(failWith: .claudeCLINotFound)
        let model = makeModel(registry: nil, listener: nil, plugin: plugin)
        await model.installPlugin()

        // Owner rule: no long text in the pane. The pane gets one sentence; the
        // detail goes to the alert and the log.
        XCTAssertEqual(model.pluginResult, "Claude Code CLI not found.")
        XCTAssertLessThan(model.pluginResult?.count ?? .max, 60)
        XCTAssertNotNil(model.alert)
        XCTAssertTrue(model.alert?.detail.contains("PATH") ?? false)
    }

    func testAFailedCommandNeverPutsTheCLIOutputInThePane() async {
        let noise = String(repeating: "stack trace line\n", count: 200)
        let plugin = StubPluginService(failWith: .commandFailed(action: .install, exitCode: 2, message: noise))
        let model = makeModel(registry: nil, listener: nil, plugin: plugin)
        await model.installPlugin()

        XCTAssertEqual(model.pluginResult, "Claude Code reported an error.")
        XCTAssertFalse(model.pluginResult?.contains("stack trace") ?? true)
        XCTAssertTrue(model.alert?.detail.contains("stack trace") ?? false, "the detail belongs in the alert")
    }

    // MARK: Enrollment → listener lifecycle

    func testTheFirstEnrollmentBindsTheListenerWithoutARelaunch() async throws {
        let registry = try makeRegistry()
        let listener = StubListener(hosts: registry)
        let model = makeModel(registry: registry, listener: listener)
        XCTAssertFalse(listener.isListening)
        XCTAssertEqual(model.listenerStatus, .idle)

        model.enrollLabel = "buildhost"
        model.enrollSSHAlias = "builder"
        await model.enroll()

        // The whole point. "Enroll a host, then quit and reopen the app" is not
        // a step anyone would guess, and skipping it fails SILENTLY: the tunnel
        // hits a closed port and the hook fails open.
        XCTAssertTrue(listener.isListening)
        XCTAssertEqual(model.listenerStatus, .listening(port: 8473))
        XCTAssertEqual(listener.reconcileCount, 1)
    }

    func testLaunchSyncPreservesFailureStatusWithoutQueueingALateModal() throws {
        let registry = try makeRegistry()
        _ = try registry.enroll(label: "builder")
        let listener = StubListener(hosts: registry)
        #if canImport(Darwin)
        listener.bindError = ClaudeRemoteContextListener.StartFailure.bindFailed(errno: EADDRINUSE)
        #else
        listener.bindError = ClaudeRemoteContextListener.StartFailure.bindFailed(errno: 48)
        #endif
        let model = makeModel(registry: registry, listener: listener)

        model.synchronizeListenerAtLaunch()

        XCTAssertEqual(model.listenerStatus, .portConflict(port: 8473))
        XCTAssertNil(model.alert)
        XCTAssertEqual(listener.reconcileCount, 1)
    }

    func testRegistryPathFailuresHaveActionableCopy() {
        let detail = ClaudeIntegrationSettingsModel.registryFailureDetail(
            ClaudeSocketGuard.PreconditionFailure.permissive(path: "/tmp/claude", mode: 0o755)
        )
        XCTAssertTrue(detail.contains("unsafe permissions"))
        XCTAssertTrue(detail.contains("/tmp/claude"))
    }

    func testRevokingTheLastHostStopsListening() async throws {
        let registry = try makeRegistry()
        let listener = StubListener(hosts: registry)
        let model = makeModel(registry: registry, listener: listener)
        model.enrollLabel = "buildhost"
        model.enrollSSHAlias = "builder"
        await model.enroll()
        XCTAssertTrue(listener.isListening)

        await model.revoke(hostID: try XCTUnwrap(model.hosts.first).id)

        // No enrolled host ⇒ no open port. A feature nobody has set up must not
        // be listening on one.
        XCTAssertFalse(listener.isListening)
        XCTAssertEqual(model.listenerStatus, .idle)
        XCTAssertEqual(listener.reconcileCount, 2)
    }

    func testRevokingOneOfTwoHostsKeepsListening() async throws {
        let registry = try makeRegistry()
        let listener = StubListener(hosts: registry)
        let model = makeModel(registry: registry, listener: listener)
        for alias in ["builder", "otherbox"] {
            model.enrollLabel = alias
            model.enrollSSHAlias = alias
            await model.enroll()
        }
        XCTAssertEqual(model.hosts.count, 2)

        await model.revoke(hostID: try XCTUnwrap(model.hosts.first).id)

        XCTAssertTrue(listener.isListening, "the surviving host still needs the port")
        XCTAssertEqual(listener.reconcileCount, 3, "every registry mutation must reconcile")
    }

    func testRemovingTheLastHostStopsListening() async throws {
        let registry = try makeRegistry()
        let listener = StubListener(hosts: registry)
        let model = makeModel(registry: registry, listener: listener)
        model.enrollLabel = "buildhost"
        model.enrollSSHAlias = "builder"
        await model.enroll()

        await model.remove(hostID: try XCTUnwrap(model.hosts.first).id)

        XCTAssertTrue(model.hosts.isEmpty)
        XCTAssertFalse(listener.isListening)
    }

    func testRotatingARevokedHostRebindsTheListener() async throws {
        let registry = try makeRegistry()
        let listener = StubListener(hosts: registry)
        let model = makeModel(registry: registry, listener: listener)
        model.enrollLabel = "buildhost"
        model.enrollSSHAlias = "builder"
        await model.enroll()
        let hostID = try XCTUnwrap(model.hosts.first).id
        await model.revoke(hostID: hostID)
        XCTAssertFalse(listener.isListening)

        await model.rotate(hostID: hostID)

        // Rotation reinstates a revoked host — handing out a credential is the
        // same act as enrolling — so it is a 0→1 transition and must rebind.
        XCTAssertTrue(listener.isListening)
    }

    // MARK: The token

    func testEnrollmentShowsTheTokenExactlyOnceAndThenForgetsIt() async throws {
        let registry = try makeRegistry()
        let model = makeModel(registry: registry, listener: StubListener(hosts: registry))
        model.enrollLabel = "buildhost"
        model.enrollSSHAlias = "builder"
        await model.enroll()

        let plan = try XCTUnwrap(model.presentedPlan)
        XCTAssertFalse(plan.isRotation)
        XCTAssertTrue(ClaudeRemoteTokenDigest.isWellFormed(plan.token))
        XCTAssertTrue(plan.plan.remoteCommands.joined().contains(plan.token))
        // The install command needs it; the ssh config must not have it. That
        // file gets copied between machines and pasted into issues.
        XCTAssertFalse(plan.plan.sshConfigSnippet.contains(plan.token))

        model.dismissPlan()

        // The registry stores only hashes, so nothing anywhere can produce this
        // token again. Rotation is the recovery path, deliberately.
        XCTAssertNil(model.presentedPlan)
    }

    func testTheFormIsClearedAfterEnrollingSoTheNextHostStartsBlank() async throws {
        let registry = try makeRegistry()
        let model = makeModel(registry: registry, listener: StubListener(hosts: registry))
        model.enrollLabel = "buildhost"
        model.enrollSSHAlias = "builder"
        await model.enroll()
        XCTAssertEqual(model.enrollLabel, "")
        XCTAssertEqual(model.enrollSSHAlias, "")
    }

    func testRotationPresentsTheNewTokenAndSaysItIsARotation() async throws {
        let registry = try makeRegistry()
        let model = makeModel(registry: registry, listener: StubListener(hosts: registry))
        model.enrollLabel = "buildhost"
        model.enrollSSHAlias = "builder"
        await model.enroll()
        let first = try XCTUnwrap(model.presentedPlan).token
        model.dismissPlan()

        await model.rotate(hostID: try XCTUnwrap(model.hosts.first).id)

        let rotated = try XCTUnwrap(model.presentedPlan)
        XCTAssertTrue(rotated.isRotation)
        XCTAssertNotEqual(rotated.token, first)
        XCTAssertNil(registry.authenticate(token: first), "rotation has no grace period")
        XCTAssertNotNil(registry.authenticate(token: rotated.token))
    }

    func testRemoteSetupDoesNotRunBeforeExplicitConfirmation() async throws {
        let registry = try makeRegistry()
        let calls = Mutex<[ClaudeRemoteEnrollmentService.Invocation]>([])
        let service = ClaudeRemoteEnrollmentService(runner: { invocation in
            calls.withLock { $0.append(invocation) }
            return .init(exitCode: 0, message: "ok")
        })
        let model = makeModel(
            registry: registry,
            listener: StubListener(hosts: registry),
            enrollmentService: service
        )
        model.enrollLabel = "buildhost"
        model.enrollSSHAlias = "builder"
        await model.enroll()
        let token = try XCTUnwrap(model.presentedPlan).token

        model.requestRemoteSetup()

        XCTAssertTrue(calls.withLock { $0 }.isEmpty)
        let confirmation = try XCTUnwrap(model.enrollmentConfirmation)
        XCTAssertFalse(confirmation.preview.contains(token))
        XCTAssertTrue(confirmation.preview.contains(ClaudeRemoteTokenRedaction.placeholder))

        await model.confirmEnrollmentAction()

        XCTAssertEqual(calls.withLock { $0 }.count, 2)
        XCTAssertEqual(model.enrollmentStepStatuses.map(\.text), [
            "Step 1 succeeded.", "Step 2 succeeded.",
        ])
    }

    func testCancellingTheConfirmationRunsNothing() async throws {
        let registry = try makeRegistry()
        let calls = Mutex<[ClaudeRemoteEnrollmentService.Invocation]>([])
        let service = ClaudeRemoteEnrollmentService(runner: { invocation in
            calls.withLock { $0.append(invocation) }
            return .init(exitCode: 0, message: "ok")
        })
        let model = makeModel(
            registry: registry,
            listener: StubListener(hosts: registry),
            enrollmentService: service
        )
        model.enrollLabel = "buildhost"
        model.enrollSSHAlias = "builder"
        await model.enroll()

        model.requestRemoteSetup()
        model.cancelEnrollmentActionConfirmation()

        XCTAssertNil(model.enrollmentConfirmation)
        // Cancel is the user's only exit short of confirming: after it, the
        // confirm entry point must be a no-op.
        await model.confirmEnrollmentAction()
        XCTAssertTrue(calls.withLock { $0 }.isEmpty)
        XCTAssertTrue(model.enrollmentStepStatuses.isEmpty)
    }

    func testANewEnrollmentSheetDoesNotInheritThePreviousHostsStepResults() async throws {
        let registry = try makeRegistry()
        let service = ClaudeRemoteEnrollmentService(runner: { _ in
            .init(exitCode: 0, message: "ok")
        })
        let model = makeModel(
            registry: registry,
            listener: StubListener(hosts: registry),
            enrollmentService: service
        )
        model.enrollLabel = "first"
        model.enrollSSHAlias = "builder"
        await model.enroll()
        model.requestRemoteSetup()
        await model.confirmEnrollmentAction()
        XCTAssertFalse(model.enrollmentStepStatuses.isEmpty)

        model.dismissPlan()
        model.enrollLabel = "second"
        model.enrollSSHAlias = "builder2"
        await model.enroll()

        XCTAssertNotNil(model.presentedPlan)
        XCTAssertTrue(model.enrollmentStepStatuses.isEmpty)
        XCTAssertNil(model.enrollmentConfirmation)
        XCTAssertNil(model.enrollmentResultsAction)
    }

    func testSSHConfigInsertionDoesNotTouchFilesystemBeforeExplicitConfirmation() async throws {
        let registry = try makeRegistry()
        let fileSystem = RecordingSSHConfigFileSystem()
        let service = ClaudeRemoteEnrollmentService(sshConfigFileSystem: fileSystem)
        let model = makeModel(
            registry: registry,
            listener: StubListener(hosts: registry),
            enrollmentService: service
        )
        model.enrollLabel = "buildhost"
        model.enrollSSHAlias = "builder"
        await model.enroll()

        model.requestSSHConfigInsertion()

        XCTAssertEqual(fileSystem.readCount, 0)
        XCTAssertEqual(fileSystem.writeCount, 0)
        XCTAssertEqual(
            model.enrollmentConfirmation?.preview,
            model.presentedPlan?.plan.sshConfigSnippet
        )

        await model.confirmEnrollmentAction()

        XCTAssertEqual(fileSystem.readCount, 1)
        XCTAssertEqual(fileSystem.writeCount, 1)
        XCTAssertEqual(
            model.enrollmentStepStatuses.first?.text,
            "Inserted this host's block into ~/.ssh/config."
        )
        XCTAssertEqual(model.enrollmentResultsAction, .insertSSHConfig)
    }

    /// Field report 2026-07-26: the step-1 success rendered in a pooled results
    /// area below step 2, the owner never saw it, and confirmed the insertion
    /// twice believing it had done nothing. The sheet now renders each outcome
    /// inside the section that ran it, which needs the model to say WHICH
    /// action the statuses belong to — and to clear that tag the moment a new
    /// confirmation starts, so step 1's stale result can never render while
    /// step 2 is the one being confirmed.
    func testStepResultsAreTaggedWithTheActionThatProducedThem() async throws {
        let registry = try makeRegistry()
        let fileSystem = RecordingSSHConfigFileSystem()
        let service = ClaudeRemoteEnrollmentService(
            runner: { _ in .init(exitCode: 1, message: "remote said no") },
            sshConfigFileSystem: fileSystem
        )
        let model = makeModel(
            registry: registry,
            listener: StubListener(hosts: registry),
            enrollmentService: service
        )
        model.enrollLabel = "buildhost"
        model.enrollSSHAlias = "builder"
        await model.enroll()
        XCTAssertNil(model.enrollmentResultsAction)

        model.requestSSHConfigInsertion()
        await model.confirmEnrollmentAction()
        XCTAssertEqual(model.enrollmentResultsAction, .insertSSHConfig)

        model.requestRemoteSetup()
        XCTAssertNil(model.enrollmentResultsAction, "a pending confirmation must not show stale results")
        XCTAssertTrue(model.enrollmentStepStatuses.isEmpty)

        await model.confirmEnrollmentAction()
        XCTAssertEqual(model.enrollmentResultsAction, .runRemoteSetup)
        XCTAssertEqual(model.enrollmentStepStatuses.first?.succeeded, false)
    }

    /// Review finding (PR #194): the late-result guard compared only
    /// `host.id`, which token rotation REUSES — a setup still in flight when
    /// the sheet went away could publish its old-token outcome underneath the
    /// rotation sheet that replaced it. The guard now requires the whole
    /// presentation to match; rotation mints a new token, so equality
    /// distinguishes the generations.
    func testALateResultFromBeforeARotationNeverSurfacesUnderTheNewToken() async throws {
        let registry = try makeRegistry()
        let (gate, releaseGate) = AsyncStream.makeStream(of: Void.self)
        let service = ClaudeRemoteEnrollmentService(runner: { _ in
            .init(exitCode: 0, message: "ok")
        })
        let model = ClaudeIntegrationSettingsModel(
            registry: registry,
            listener: StubListener(hosts: registry),
            pluginService: { StubPluginService() },
            enrollmentService: service,
            performAsync: { body in
                do {
                    try body()
                    return nil
                } catch {
                    return ClaudePluginActionFailure(error)
                }
            },
            performEnrollmentAsync: { body in
                // Park until the test releases the gate, so the "sheet went
                // away and the user rotated while ssh was still running"
                // interleaving is deterministic — cooperative yields only, no
                // wall-clock.
                var latch = gate.makeAsyncIterator()
                _ = await latch.next()
                do {
                    return ClaudeEnrollmentActionAttempt(steps: try body(), failure: nil)
                } catch {
                    return ClaudeEnrollmentActionAttempt(
                        steps: [],
                        failure: ClaudeEnrollmentActionFailure(error)
                    )
                }
            },
            now: { Date(timeIntervalSince1970: 1_000_000) }
        )
        model.enrollLabel = "buildhost"
        model.enrollSSHAlias = "builder"
        await model.enroll()
        let hostID = try XCTUnwrap(model.presentedPlan).host.id

        model.requestRemoteSetup()
        let inFlight = Task { await model.confirmEnrollmentAction() }
        while !model.isPerformingEnrollmentAction { await Task.yield() }

        model.dismissPlan()
        await model.rotate(hostID: hostID)
        XCTAssertEqual(
            model.presentedPlan?.host.id, hostID,
            "rotation reuses the host id — that reuse is the trap"
        )

        releaseGate.yield(())
        releaseGate.finish()
        await inFlight.value

        XCTAssertTrue(
            model.enrollmentStepStatuses.isEmpty,
            "an old-token result must not render under the rotation sheet"
        )
        XCTAssertNil(model.enrollmentResultsAction)
    }

    func testRemoteSetupTimeoutHasShortStepStatusAndClearDetail() async throws {
        let registry = try makeRegistry()
        let service = ClaudeRemoteEnrollmentService(runner: { _ in
            throw ClaudeRemoteEnrollmentService.RunnerFailure.timedOut(
                seconds: 15,
                message: "connection stalled"
            )
        })
        let model = makeModel(
            registry: registry,
            listener: StubListener(hosts: registry),
            enrollmentService: service
        )
        model.enrollLabel = "buildhost"
        model.enrollSSHAlias = "builder"
        await model.enroll()
        model.requestRemoteSetup()

        await model.confirmEnrollmentAction()

        XCTAssertEqual(model.enrollmentStepStatuses.first?.text, "Step 1 failed.")
        XCTAssertTrue(model.alert?.detail.contains("within 15s") ?? false)
        XCTAssertTrue(model.alert?.detail.contains("connection stalled") ?? false)
    }

    // MARK: Remote plugin update

    private func enrolledModel(
        label: String,
        alias: String = "builder",
        registry: ClaudeRemoteHostRegistry,
        service: ClaudeRemoteEnrollmentService,
        remoteForwardPort: UInt16 = ClaudeRemoteForwardPort.legacyPort
    ) async -> ClaudeIntegrationSettingsModel {
        let model = makeModel(
            registry: registry,
            listener: StubListener(hosts: registry),
            enrollmentService: service,
            remoteForwardPort: remoteForwardPort
        )
        model.enrollLabel = label
        model.enrollSSHAlias = alias
        await model.enroll()
        model.dismissPlan()
        return model
    }

    /// `claude plugin install` is not an update — on Claude Code 2.1.220 it
    /// exits 0 on an installed plugin and leaves the old version in place — so
    /// an enrolled host has no way to receive a plugin fix without this action.
    func testPluginUpdateShowsThatHostsCommandsAndRunsNothingYet() async throws {
        let registry = try makeRegistry()
        let calls = Mutex<[ClaudeRemoteEnrollmentService.Invocation]>([])
        let service = ClaudeRemoteEnrollmentService(
            runner: { invocation in
                calls.withLock { $0.append(invocation) }
                return .init(exitCode: 0, message: "ok")
            },
            // The update path rewrites this host's ssh block in the same
            // action now (review blocker), so it needs somewhere to write.
            sshConfigFileSystem: RecordingSSHConfigFileSystem()
        )
        // Name and SSH alias are separate fields on the enrollment form, and
        // this is the pairing that made the review finding concrete: a host
        // NAMED prod, REACHED as builder.
        let model = await enrolledModel(
            label: "prod", alias: "builder", registry: registry, service: service
        )
        let hostID = try XCTUnwrap(model.hosts.first).id

        model.requestPluginUpdate(hostID: hostID)

        let update = try XCTUnwrap(model.presentedPluginUpdate)
        XCTAssertEqual(update.hostID, hostID)
        XCTAssertEqual(
            update.sshHostAlias, "builder",
            "the update must target the enrolled alias, never the display name"
        )
        XCTAssertTrue(update.canRun)
        let commands = update.commands.joined(separator: "\n")
        XCTAssertTrue(commands.contains("ssh builder "))
        XCTAssertFalse(commands.contains("ssh prod "), "updating the wrong host is the whole risk")
        XCTAssertTrue(commands.contains("claude plugin update"))
        XCTAssertTrue(calls.withLock { $0 }.isEmpty, "disclosure must not run anything")
        XCTAssertNil(model.enrollmentConfirmation)
    }

    /// Every artifact the pane hands the user must name the SAME remote port —
    /// this Mac's allocation (#215). One that names a different port than
    /// another is a tunnel to nothing, and it fails open, i.e. silently.
    func testEveryGeneratedArtifactUsesThisMacsAllocatedRemotePort() async throws {
        let registry = try makeRegistry()
        let calls = Mutex<[ClaudeRemoteEnrollmentService.Invocation]>([])
        let service = ClaudeRemoteEnrollmentService(
            runner: { invocation in
                calls.withLock { $0.append(invocation) }
                return .init(exitCode: 0, message: "ok")
            },
            sshConfigFileSystem: RecordingSSHConfigFileSystem()
        )
        let model = makeModel(
            registry: registry,
            listener: StubListener(hosts: registry),
            enrollmentService: service,
            remoteForwardPort: 28542
        )
        model.enrollLabel = "buildhost"
        model.enrollSSHAlias = "builder"

        await model.enroll()

        let plan = try XCTUnwrap(model.presentedPlan).plan
        XCTAssertTrue(
            plan.sshConfigSnippet.contains("RemoteForward 28542 127.0.0.1:8473"),
            plan.sshConfigSnippet
        )
        XCTAssertTrue(plan.remoteCommands.joined().contains("--config 'port=28542'"))
        XCTAssertTrue(plan.verifyCommands.joined().contains("127.0.0.1:28542"))
        XCTAssertTrue(plan.updateCommands.joined().contains("--config 'port=28542'"))
        model.dismissPlan()

        // …and so must the standalone update panel and what it actually runs.
        let hostID = try XCTUnwrap(model.hosts.first).id
        model.requestPluginUpdate(hostID: hostID)
        let update = try XCTUnwrap(model.presentedPluginUpdate)
        XCTAssertTrue(update.commands.joined().contains("--config 'port=28542'"))

        model.requestPluginUpdateRun()
        await model.confirmEnrollmentAction()
        let scripts = calls.withLock { $0 }.map { String(decoding: $0.standardInput, as: UTF8.self) }
        XCTAssertTrue(
            scripts.contains { $0.contains("--config 'port=28542'") },
            "the executed update must migrate the port, not just the panel text: \(scripts)"
        )
    }

    // MARK: Update migrates BOTH halves (review blocker)

    /// The failure this pins, in full: a legacy host's block says
    /// `RemoteForward 8473`, this Mac now allocates 285xx, and the update
    /// stores `port=285xx` on the remote. If only that half runs, every hook on
    /// that host posts to a port this Mac does not forward — connection
    /// refused, fail open, silence. That is #215's failure class, reintroduced
    /// by the fix for #215, and it would have shipped to every legacy user who
    /// pressed the button.
    func testUpdatingALegacyHostRewritesTheSSHBlockAndTheRemotePortTogether() async throws {
        let registry = try makeRegistry()
        let calls = Mutex<[ClaudeRemoteEnrollmentService.Invocation]>([])
        let filesystem = RecordingSSHConfigFileSystem()
        let service = ClaudeRemoteEnrollmentService(
            runner: { invocation in
                calls.withLock { $0.append(invocation) }
                return .init(exitCode: 0, message: "ok")
            },
            sshConfigFileSystem: filesystem
        )
        let model = makeModel(
            registry: registry,
            listener: StubListener(hosts: registry),
            enrollmentService: service,
            remoteForwardPort: 28542
        )
        model.enrollLabel = "buildhost"
        model.enrollSSHAlias = "builder"
        await model.enroll()
        model.dismissPlan()
        let hostID = try XCTUnwrap(model.hosts.first).id

        // The legacy state: a block written before per-Mac ports existed.
        let legacyHost = try XCTUnwrap(registry.host(id: hostID))
        let legacyBlock = ClaudeRemoteEnrollmentService.applySSHConfigSnippet(
            to: "Host unrelated\n    HostName 10.0.0.9\n",
            snippet: ClaudeRemoteEnrollmentService.sshConfigSnippet(
                host: legacyHost,
                sshHostAlias: "builder",
                listenerPort: 8473,
                remoteForwardPort: 8473
            ),
            hostID: hostID
        )
        filesystem.setConfig(legacyBlock)

        model.requestPluginUpdate(hostID: hostID)
        let update = try XCTUnwrap(model.presentedPluginUpdate)
        let snippet = try XCTUnwrap(
            update.sshConfigSnippet,
            "a stale block must be regenerated as part of this action, not left behind"
        )
        XCTAssertTrue(snippet.contains("RemoteForward 28542 127.0.0.1:8473"))

        // The confirmation has to repeat BOTH mutations, in order.
        model.requestPluginUpdateRun()
        let preview = try XCTUnwrap(model.enrollmentConfirmation).preview
        XCTAssertTrue(preview.contains("RemoteForward 28542 127.0.0.1:8473"), preview)
        XCTAssertTrue(preview.contains("--config 'port=28542'"), preview)

        await model.confirmEnrollmentAction()

        // Half one: the local block now forwards the allocated port, once.
        let written = try XCTUnwrap(filesystem.lastWrittenText)
        XCTAssertTrue(written.contains("RemoteForward 28542 127.0.0.1:8473"), written)
        XCTAssertFalse(written.contains("RemoteForward 8473"), "the stale line must be gone: \(written)")
        XCTAssertEqual(
            written.components(separatedBy: "Host builder").count - 1, 1,
            "a duplicate stanza would let the stale one win by first-match"
        )
        XCTAssertTrue(written.contains("Host unrelated"), "the rest of the file is untouched")

        // Half two: the remote now stores the same port.
        let scripts = calls.withLock { $0 }.map { String(decoding: $0.standardInput, as: UTF8.self) }
        XCTAssertTrue(
            scripts.contains { $0.contains("--config 'port=28542'") },
            "the plugin-side port write must have run too: \(scripts)"
        )
        XCTAssertTrue(model.enrollmentStepStatuses.allSatisfy(\.succeeded))
    }

    /// The half of the blocker that the first fix missed: the executable path
    /// wrote the ssh block, but the PANEL displayed and copied only the remote
    /// commands. Both copy-only routes lead straight back to the split brain —
    /// a host with no recorded alias can ONLY be updated by hand, and the
    /// symlink refusal deliberately sends the user to that same Copy button.
    /// So the copy payload has to carry both mutations, in order.
    func testTheCopyPayloadForAnAliaslessHostCarriesTheSSHBlockToo() async throws {
        let registry = try makeRegistry()
        let filesystem = RecordingSSHConfigFileSystem()
        let service = ClaudeRemoteEnrollmentService(
            runner: { _ in .init(exitCode: 0, message: "ok") },
            sshConfigFileSystem: filesystem
        )
        // Enrolled before aliases were recorded: copy-only, forever, until the
        // user re-enrolls. This is the population most likely to still be on a
        // legacy 8473 block.
        let enrollment = try registry.enroll(label: "buildhost")
        let model = makeModel(
            registry: registry,
            listener: StubListener(hosts: registry),
            enrollmentService: service,
            remoteForwardPort: 28542
        )

        model.requestPluginUpdate(hostID: enrollment.host.id)

        let update = try XCTUnwrap(model.presentedPluginUpdate)
        XCTAssertFalse(update.canRun, "no alias means nothing may be run for them")
        let payload = update.applicationText
        XCTAssertTrue(
            payload.contains("RemoteForward 28542 127.0.0.1:8473"),
            "a copy that omits the ssh block updates the remote and strands this Mac: \(payload)"
        )
        XCTAssertTrue(payload.contains("--config 'port=28542'"), payload)
        // Order matters as much as presence: the block first, the remote second.
        let blockIndex = try XCTUnwrap(payload.range(of: "RemoteForward 28542")).lowerBound
        let commandIndex = try XCTUnwrap(payload.range(of: "--config 'port=28542'")).lowerBound
        XCTAssertLessThan(blockIndex, commandIndex)
        XCTAssertTrue(payload.contains("~/.ssh/config"), "and it must say where the block goes")
    }

    /// The recovery path after the app refuses to write a symlinked config: the
    /// user is told to copy, so what they copy must be enough to finish the job.
    func testTheCopyPayloadAfterASymlinkRefusalStillCarriesTheSSHBlock() async throws {
        let registry = try makeRegistry()
        let calls = Mutex<[ClaudeRemoteEnrollmentService.Invocation]>([])
        let filesystem = RecordingSSHConfigFileSystem()
        filesystem.setSymlinked(true)
        let service = ClaudeRemoteEnrollmentService(
            runner: { invocation in
                calls.withLock { $0.append(invocation) }
                return .init(exitCode: 0, message: "ok")
            },
            sshConfigFileSystem: filesystem
        )
        let model = makeModel(
            registry: registry,
            listener: StubListener(hosts: registry),
            enrollmentService: service,
            remoteForwardPort: 28542
        )
        model.enrollLabel = "buildhost"
        model.enrollSSHAlias = "builder"
        await model.enroll()
        model.dismissPlan()
        let hostID = try XCTUnwrap(model.hosts.first).id

        model.requestPluginUpdate(hostID: hostID)
        model.requestPluginUpdateRun()
        await model.confirmEnrollmentAction()

        XCTAssertTrue(calls.withLock { $0 }.isEmpty, "the remote must stay untouched")
        // The panel is still open, and what it offers to copy is the whole job.
        let payload = try XCTUnwrap(model.presentedPluginUpdate).applicationText
        XCTAssertTrue(
            payload.contains("RemoteForward 28542 127.0.0.1:8473"),
            "the refusal tells the user to copy; copying must hand them both halves: \(payload)"
        )
        XCTAssertTrue(payload.contains("--config 'port=28542'"))
    }

    func testThePanelTheConfirmationAndTheCopyAllShowTheSameText() async throws {
        // Three surfaces rendered the same thing by hand once, and diverged —
        // that divergence WAS the blocker. One source now.
        let registry = try makeRegistry()
        let service = ClaudeRemoteEnrollmentService(
            runner: { _ in .init(exitCode: 0, message: "ok") },
            sshConfigFileSystem: RecordingSSHConfigFileSystem()
        )
        let model = makeModel(
            registry: registry,
            listener: StubListener(hosts: registry),
            enrollmentService: service,
            remoteForwardPort: 28542
        )
        model.enrollLabel = "buildhost"
        model.enrollSSHAlias = "builder"
        await model.enroll()
        model.dismissPlan()
        let hostID = try XCTUnwrap(model.hosts.first).id

        model.requestPluginUpdate(hostID: hostID)
        model.requestPluginUpdateRun()

        let update = try XCTUnwrap(model.presentedPluginUpdate)
        XCTAssertEqual(
            try XCTUnwrap(model.enrollmentConfirmation).preview,
            update.applicationText,
            "the confirmation must be the same text the panel shows and copies"
        )
        XCTAssertEqual(
            ClaudeIntegrationSettingsModel.updatePreview(for: update),
            update.applicationText
        )
    }

    func testAHostWhoseBlockIsAlreadyCurrentIsNotRewritten() async throws {
        let registry = try makeRegistry()
        let filesystem = RecordingSSHConfigFileSystem()
        let service = ClaudeRemoteEnrollmentService(
            runner: { _ in .init(exitCode: 0, message: "ok") },
            sshConfigFileSystem: filesystem
        )
        let model = makeModel(
            registry: registry,
            listener: StubListener(hosts: registry),
            enrollmentService: service,
            remoteForwardPort: 28542
        )
        model.enrollLabel = "buildhost"
        model.enrollSSHAlias = "builder"
        await model.enroll()
        model.dismissPlan()
        let hostID = try XCTUnwrap(model.hosts.first).id
        let host = try XCTUnwrap(registry.host(id: hostID))
        filesystem.setConfig(
            ClaudeRemoteEnrollmentService.applySSHConfigSnippet(
                to: "",
                snippet: ClaudeRemoteEnrollmentService.sshConfigSnippet(
                    host: host,
                    sshHostAlias: "builder",
                    listenerPort: 8473,
                    remoteForwardPort: 28542
                ),
                hostID: hostID
            )
        )

        model.requestPluginUpdate(hostID: hostID)

        XCTAssertNil(
            try XCTUnwrap(model.presentedPluginUpdate).sshConfigSnippet,
            "an up-to-date block is not a mutation to ask the user to confirm"
        )
    }

    /// Order is the safety property: if the local write fails, the REMOTE must
    /// be untouched. The reverse order would leave the plugin pointed at a port
    /// this Mac does not forward — silently — which is the state this whole
    /// change exists to make unreachable.
    func testARefusedLocalWriteLeavesTheRemoteCompletelyUntouched() async throws {
        let registry = try makeRegistry()
        let calls = Mutex<[ClaudeRemoteEnrollmentService.Invocation]>([])
        let filesystem = RecordingSSHConfigFileSystem()
        filesystem.setSymlinked(true)
        let service = ClaudeRemoteEnrollmentService(
            runner: { invocation in
                calls.withLock { $0.append(invocation) }
                return .init(exitCode: 0, message: "ok")
            },
            sshConfigFileSystem: filesystem
        )
        let model = makeModel(
            registry: registry,
            listener: StubListener(hosts: registry),
            enrollmentService: service,
            remoteForwardPort: 28542
        )
        model.enrollLabel = "buildhost"
        model.enrollSSHAlias = "builder"
        await model.enroll()
        model.dismissPlan()
        let hostID = try XCTUnwrap(model.hosts.first).id

        model.requestPluginUpdate(hostID: hostID)
        model.requestPluginUpdateRun()
        await model.confirmEnrollmentAction()

        XCTAssertTrue(
            calls.withLock { $0 }.isEmpty,
            "nothing may reach the remote once the local half is known to have failed"
        )
        XCTAssertNotNil(model.alert, "and the user has to be told")
    }

    /// The same confusion on the rotation path, which is worse: it hands a
    /// FRESH token to whatever answers to the guessed name.
    func testRotationTargetsTheEnrolledAliasNotTheDisplayName() async throws {
        let registry = try makeRegistry()
        let service = ClaudeRemoteEnrollmentService(runner: { _ in .init(exitCode: 0, message: "ok") })
        let model = await enrolledModel(
            label: "prod", alias: "builder", registry: registry, service: service
        )
        let hostID = try XCTUnwrap(model.hosts.first).id

        await model.rotate(hostID: hostID)

        let presentation = try XCTUnwrap(model.presentedPlan)
        XCTAssertEqual(presentation.sshHostAlias, "builder")
        XCTAssertTrue(presentation.canRunRemoteSetup)
        XCTAssertTrue(presentation.plan.verifyCommands.joined().contains("ssh builder"))
        XCTAssertFalse(presentation.plan.updateCommands.joined().contains("ssh prod"))
    }

    func testRotatingAHostEnrolledBeforeAliasesWereRecordedIsCopyOnly() async throws {
        // No alias on file means we do not know where to send the new token,
        // and a guess is exactly what this PR removed. Copy still works.
        let registry = try makeRegistry()
        let calls = Mutex(0)
        let service = ClaudeRemoteEnrollmentService(runner: { _ in
            calls.withLock { $0 += 1 }
            return .init(exitCode: 0, message: "ok")
        })
        let enrollment = try registry.enroll(label: "buildhost")
        let model = makeModel(
            registry: registry,
            listener: StubListener(hosts: registry),
            enrollmentService: service
        )

        await model.rotate(hostID: enrollment.host.id)

        let presentation = try XCTUnwrap(model.presentedPlan)
        XCTAssertFalse(presentation.canRunRemoteSetup)
        XCTAssertEqual(
            presentation.sshHostAlias,
            ClaudeIntegrationSettingsModel.unknownAliasPlaceholder,
            "the label is not a stand-in for an alias we were never told"
        )

        model.requestRemoteSetup()
        await model.confirmEnrollmentAction()

        XCTAssertNil(model.enrollmentConfirmation)
        XCTAssertEqual(calls.withLock { $0 }, 0, "a placeholder alias must never reach ssh")
    }

    func testPluginUpdateRunsOnlyAfterAnExplicitConfirmation() async throws {
        let registry = try makeRegistry()
        let calls = Mutex<[ClaudeRemoteEnrollmentService.Invocation]>([])
        let service = ClaudeRemoteEnrollmentService(
            runner: { invocation in
                calls.withLock { $0.append(invocation) }
                return .init(exitCode: 0, message: "ok")
            },
            sshConfigFileSystem: RecordingSSHConfigFileSystem()
        )
        let model = await enrolledModel(label: "buildhost", registry: registry, service: service)
        let hostID = try XCTUnwrap(model.hosts.first).id
        model.requestPluginUpdate(hostID: hostID)

        model.requestPluginUpdateRun()

        XCTAssertTrue(calls.withLock { $0 }.isEmpty)
        let confirmation = try XCTUnwrap(model.enrollmentConfirmation)
        XCTAssertEqual(confirmation.action, .updateRemotePlugin(hostID: hostID))
        XCTAssertEqual(
            confirmation.preview,
            ClaudeIntegrationSettingsModel.updatePreview(
                for: try XCTUnwrap(model.presentedPluginUpdate)
            ),
            "the confirmation must repeat the exact mutations the row displays"
        )
        XCTAssertTrue(
            confirmation.preview.contains(
                try XCTUnwrap(model.presentedPluginUpdate).commands.joined(separator: "\n")
            ),
            "…including every command, verbatim"
        )

        await model.confirmEnrollmentAction()

        // Three since per-Mac ports (#215): marketplace update, plugin update,
        // and the token-free `--config port=` migration for a host enrolled
        // before that option existed.
        XCTAssertEqual(calls.withLock { $0 }.count, 3)
        XCTAssertEqual(model.enrollmentStepStatuses.map(\.text), [
            "Step 1 succeeded.", "Step 2 succeeded.", "Step 3 succeeded.",
        ])
        XCTAssertEqual(model.enrollmentResultsAction, .updateRemotePlugin(hostID: hostID))
    }

    func testCancellingThePluginUpdateConfirmationRunsNothing() async throws {
        let registry = try makeRegistry()
        let calls = Mutex<[ClaudeRemoteEnrollmentService.Invocation]>([])
        let service = ClaudeRemoteEnrollmentService(runner: { invocation in
            calls.withLock { $0.append(invocation) }
            return .init(exitCode: 0, message: "ok")
        })
        let model = await enrolledModel(label: "buildhost", registry: registry, service: service)
        let hostID = try XCTUnwrap(model.hosts.first).id
        model.requestPluginUpdate(hostID: hostID)
        model.requestPluginUpdateRun()

        model.cancelEnrollmentActionConfirmation()
        await model.confirmEnrollmentAction()

        XCTAssertNil(model.enrollmentConfirmation)
        XCTAssertTrue(calls.withLock { $0 }.isEmpty)
        XCTAssertTrue(model.enrollmentStepStatuses.isEmpty)
    }

    /// The results render in the row whose button ran them (PR #194), so the
    /// tag has to name the HOST as well as the action — and opening another
    /// host's panel must not leave the first host's outcome sitting under it.
    func testAnotherHostsPanelDoesNotInheritThePreviousResults() async throws {
        let registry = try makeRegistry()
        let service = ClaudeRemoteEnrollmentService(runner: { _ in .init(exitCode: 0, message: "ok") })
        let model = await enrolledModel(label: "buildhost", registry: registry, service: service)
        model.enrollLabel = "laptop"
        model.enrollSSHAlias = "laptop"
        await model.enroll()
        model.dismissPlan()
        let firstID = try XCTUnwrap(model.hosts.first).id
        let secondID = try XCTUnwrap(model.hosts.last).id
        XCTAssertNotEqual(firstID, secondID)

        model.requestPluginUpdate(hostID: firstID)
        model.requestPluginUpdateRun()
        await model.confirmEnrollmentAction()
        XCTAssertEqual(model.enrollmentResultsAction, .updateRemotePlugin(hostID: firstID))

        model.requestPluginUpdate(hostID: secondID)

        XCTAssertEqual(model.presentedPluginUpdate?.hostID, secondID)
        XCTAssertTrue(model.enrollmentStepStatuses.isEmpty)
        XCTAssertNil(model.enrollmentResultsAction)
        XCTAssertNil(model.enrollmentConfirmation)
    }

    func testPluginUpdateIsCopyOnlyForAHostWithNoRecordedAlias() async throws {
        // Hosts enrolled before the alias was persisted. The row says what it
        // does not know instead of ssh-ing at a name it made up.
        let registry = try makeRegistry()
        let calls = Mutex(0)
        let service = ClaudeRemoteEnrollmentService(runner: { _ in
            calls.withLock { $0 += 1 }
            return .init(exitCode: 0, message: "ok")
        })
        let enrollment = try registry.enroll(label: "buildhost")
        let model = makeModel(
            registry: registry,
            listener: StubListener(hosts: registry),
            enrollmentService: service
        )

        model.requestPluginUpdate(hostID: enrollment.host.id)

        let update = try XCTUnwrap(model.presentedPluginUpdate)
        XCTAssertNil(update.sshHostAlias)
        XCTAssertFalse(update.canRun)
        XCTAssertTrue(
            update.commands.joined(separator: "\n")
                .contains(ClaudeIntegrationSettingsModel.unknownAliasPlaceholder)
        )

        model.requestPluginUpdateRun()
        await model.confirmEnrollmentAction()

        XCTAssertNil(model.enrollmentConfirmation)
        XCTAssertEqual(calls.withLock { $0 }, 0, "a placeholder alias must never reach ssh")
    }

    /// Review finding (PR #197): the removal test below waits for the update to
    /// FINISH, so it never exercised the late-result guard. This is the
    /// interleaving that guard exists for — the row goes away while ssh is
    /// still running — and it is asserted the same way rotation's is: a gate
    /// the test releases, no wall-clock.
    func testAResultFromAHostRemovedMidUpdateNeverSurfaces() async throws {
        let registry = try makeRegistry()
        let (gate, releaseGate) = AsyncStream.makeStream(of: Void.self)
        // Failing, so a leaked result would be loud: statuses AND an alert.
        let service = ClaudeRemoteEnrollmentService(runner: { _ in
            .init(exitCode: 1, message: "remote said no")
        })
        let model = ClaudeIntegrationSettingsModel(
            registry: registry,
            listener: StubListener(hosts: registry),
            pluginService: { StubPluginService() },
            enrollmentService: service,
            performAsync: { body in
                do {
                    try body()
                    return nil
                } catch {
                    return ClaudePluginActionFailure(error)
                }
            },
            performEnrollmentAsync: { body in
                var latch = gate.makeAsyncIterator()
                _ = await latch.next()
                do {
                    return ClaudeEnrollmentActionAttempt(steps: try body(), failure: nil)
                } catch {
                    return ClaudeEnrollmentActionAttempt(
                        steps: [],
                        failure: ClaudeEnrollmentActionFailure(error)
                    )
                }
            }
        )
        model.enrollLabel = "buildhost"
        model.enrollSSHAlias = "builder"
        await model.enroll()
        model.dismissPlan()
        let hostID = try XCTUnwrap(model.hosts.first).id

        model.requestPluginUpdate(hostID: hostID)
        model.requestPluginUpdateRun()
        let inFlight = Task { await model.confirmEnrollmentAction() }
        while !model.isPerformingEnrollmentAction { await Task.yield() }

        await model.remove(hostID: hostID)

        releaseGate.yield(())
        releaseGate.finish()
        await inFlight.value

        XCTAssertTrue(model.hosts.isEmpty)
        XCTAssertNil(model.presentedPluginUpdate)
        XCTAssertTrue(
            model.enrollmentStepStatuses.isEmpty,
            "a removed host's outcome has no row to render in"
        )
        XCTAssertNil(model.enrollmentResultsAction)
        XCTAssertNil(model.alert, "and no alert about a host that is gone")
    }

    func testRemovingAHostClosesItsOpenUpdatePanel() async throws {
        let registry = try makeRegistry()
        let service = ClaudeRemoteEnrollmentService(runner: { _ in .init(exitCode: 0, message: "ok") })
        let model = await enrolledModel(label: "buildhost", registry: registry, service: service)
        let hostID = try XCTUnwrap(model.hosts.first).id
        model.requestPluginUpdate(hostID: hostID)
        model.requestPluginUpdateRun()
        await model.confirmEnrollmentAction()

        await model.remove(hostID: hostID)

        XCTAssertNil(model.presentedPluginUpdate, "the row is gone; its panel must not outlive it")
        XCTAssertTrue(model.enrollmentStepStatuses.isEmpty)
        XCTAssertNil(model.enrollmentResultsAction)
    }

    func testAFailedPluginUpdateIsAShortStatusAndADetailedAlert() async throws {
        let registry = try makeRegistry()
        let service = ClaudeRemoteEnrollmentService(
            runner: { _ in
                .init(exitCode: 1, message: "plugin localvoxtral-remote not found")
            },
            // The local ssh-block rewrite runs first and must SUCCEED here, so
            // that what this test observes is the remote step failing.
            sshConfigFileSystem: RecordingSSHConfigFileSystem()
        )
        let model = await enrolledModel(label: "buildhost", registry: registry, service: service)
        let hostID = try XCTUnwrap(model.hosts.first).id
        model.requestPluginUpdate(hostID: hostID)
        model.requestPluginUpdateRun()

        await model.confirmEnrollmentAction()

        XCTAssertEqual(model.enrollmentStepStatuses.map(\.text), ["Step 1 failed."])
        XCTAssertEqual(model.enrollmentResultsAction, .updateRemotePlugin(hostID: hostID))
        XCTAssertEqual(model.alert?.title, "Remote Claude Code plugin")
        let detail = try XCTUnwrap(model.alert?.detail)
        XCTAssertTrue(detail.contains("plugin localvoxtral-remote not found"))
        // The body has to name what the user pressed. "SSH setup exited with
        // code 1" under an Update Plugin button reads as a different failure.
        XCTAssertTrue(detail.hasPrefix("Plugin update exited with code 1."))
        XCTAssertFalse(detail.contains("SSH setup"))
    }

    // MARK: Validation and failures

    func testEnrollIsRefusedUntilBothFieldsAreUsable() {
        let model = makeModel(registry: nil, listener: nil)
        XCTAssertFalse(model.canEnroll)
        model.enrollLabel = "buildhost"
        XCTAssertFalse(model.canEnroll, "an SSH alias is required — the plan cannot be written without one")
        model.enrollSSHAlias = "has spaces"
        XCTAssertFalse(model.canEnroll)
        model.enrollSSHAlias = "builder"
        XCTAssertTrue(model.canEnroll)
    }

    func testAnInvalidAliasIsReportedAndEnrollsNothing() async throws {
        let registry = try makeRegistry()
        let model = makeModel(registry: registry, listener: StubListener(hosts: registry))
        model.enrollLabel = "buildhost"
        model.enrollSSHAlias = "bad alias"
        await model.enroll()

        XCTAssertNotNil(model.alert)
        XCTAssertNil(model.presentedPlan)
        XCTAssertTrue(model.hosts.isEmpty, "a host must not be enrolled against an alias we cannot write")
    }

    func testAPortConflictIsAShortActionableStatusPlusADetailedAlert() async throws {
        let registry = try makeRegistry()
        let listener = StubListener(hosts: registry)
        listener.bindError = ClaudeRemoteContextListener.StartFailure.bindFailed(errno: EADDRINUSE)
        let model = makeModel(registry: registry, listener: listener)
        model.enrollLabel = "buildhost"
        model.enrollSSHAlias = "builder"
        await model.enroll()

        XCTAssertEqual(model.listenerStatus, .portConflict(port: 8473))
        XCTAssertEqual(model.listenerStatus.text, "Port 8473 is already in use.")
        // A status that only says "it broke" is a bug report, not a UI.
        XCTAssertNotNil(model.listenerStatus.remedy)
        XCTAssertTrue(model.alert?.detail.contains("lsof") ?? false)
        // The threat is stated where the user meets it: a squatter sees what the
        // remote sends before it is rejected.
        XCTAssertTrue(model.alert?.detail.contains("squatter") ?? false)
    }

    func testRetryAfterAPortConflictBindsOnceTheConflictClears() async throws {
        let registry = try makeRegistry()
        let listener = StubListener(hosts: registry)
        listener.bindError = ClaudeRemoteContextListener.StartFailure.bindFailed(errno: EADDRINUSE)
        let model = makeModel(registry: registry, listener: listener)
        model.enrollLabel = "buildhost"
        model.enrollSSHAlias = "builder"
        await model.enroll()
        XCTAssertEqual(model.listenerStatus, .portConflict(port: 8473))

        listener.bindError = nil
        model.retryListener()

        XCTAssertTrue(listener.isListening)
        XCTAssertEqual(model.listenerStatus, .listening(port: 8473))
    }

    // MARK: Last-heard and rejection diagnostics

    /// The row has to answer "is this host still sending me context", because a
    /// tunnel that quietly stopped looks exactly like one that works.
    func testTheHostRowAgesLastContextAgainstTheInjectedClock() {
        let seen = Date(timeIntervalSince1970: 1_000_000)
        let format = { (offset: TimeInterval) in
            ClaudeIntegrationSettingsModel.hostStatusText(
                isRevoked: false, lastSeenAt: seen, now: seen.addingTimeInterval(offset)
            )
        }
        XCTAssertEqual(format(0), "Last context: just now")
        XCTAssertEqual(format(59), "Last context: just now")
        XCTAssertEqual(format(60), "Last context: 1 min ago")
        XCTAssertEqual(format(2 * 60 + 30), "Last context: 2 min ago")
        XCTAssertEqual(format(59 * 60), "Last context: 59 min ago")
        XCTAssertEqual(format(3600), "Last context: 1 hour ago")
        XCTAssertEqual(format(5 * 3600), "Last context: 5 hours ago")
        XCTAssertEqual(format(26 * 3600), "Last context: 1 day ago")
        XCTAssertEqual(format(3 * 86_400), "Last context: 3 days ago")
        // A clock that stepped backwards must not print a negative age.
        XCTAssertEqual(format(-600), "Last context: just now")
    }

    func testAHostThatHasNeverReportedSaysSoAndARevokedOneSaysOnlyThat() {
        XCTAssertEqual(
            ClaudeIntegrationSettingsModel.hostStatusText(
                isRevoked: false, lastSeenAt: nil, now: Date(timeIntervalSince1970: 1_000_000)
            ),
            "Last context: never"
        )
        XCTAssertEqual(
            ClaudeIntegrationSettingsModel.hostStatusText(
                isRevoked: true,
                lastSeenAt: Date(timeIntervalSince1970: 999_000),
                now: Date(timeIntervalSince1970: 1_000_000)
            ),
            "Revoked",
            "a revoked host's age is not the fact the user needs"
        )
    }

    func testRefreshBuildsTheRowStatusFromTheRegistrysActivity() async throws {
        let registry = try makeRegistry()
        let model = makeModel(
            registry: registry,
            listener: StubListener(hosts: registry),
            // 10 minutes after the registry's frozen clock.
            now: { Date(timeIntervalSince1970: 1_000_600) }
        )
        model.enrollLabel = "buildhost"
        model.enrollSSHAlias = "builder"
        await model.enroll()
        XCTAssertEqual(model.hosts.first?.statusText, "Last context: never")

        registry.noteActivity(hostID: try XCTUnwrap(model.hosts.first?.id))
        model.refreshHosts()
        XCTAssertEqual(model.hosts.first?.statusText, "Last context: 10 min ago")
    }

    /// Tonight's failure, made visible: the app knew connections were being
    /// rejected and said nothing anywhere the user would look.
    func testRejectedConnectionsSurfaceAsOneShortInlineMessage() throws {
        let registry = try makeRegistry()
        let listener = StubListener(hosts: registry)
        let model = makeModel(registry: registry, listener: listener)
        XCTAssertNil(model.rejectionHint, "nothing rejected, nothing to say")

        listener.rejectionSnapshot = ClaudeRemoteRejectionTally.Snapshot(missingToken: 42)
        model.refreshHosts()

        let hint = try XCTUnwrap(model.rejectionHint)
        XCTAssertTrue(hint.contains("outdated plugin"))
        XCTAssertFalse(hint.contains("42"), "a count is noise; the KIND is the diagnosis")
        // Owner rule: no long text in the pane.
        XCTAssertLessThan(hint.count, 110)
        XCTAssertFalse(hint.contains("\n"))
    }

    func testTheHintNamesWhichKindOfRejectionItWas() {
        let hint = { (snapshot: ClaudeRemoteRejectionTally.Snapshot) in
            ClaudeIntegrationSettingsModel.rejectionHint(for: snapshot)
        }
        XCTAssertNil(hint(ClaudeRemoteRejectionTally.Snapshot()))
        XCTAssertEqual(
            hint(ClaudeRemoteRejectionTally.Snapshot(missingToken: 1)),
            "Rejected connections detected — a host may have an outdated plugin — use Update Plugin."
        )
        XCTAssertEqual(
            hint(ClaudeRemoteRejectionTally.Snapshot(unknownToken: 1)),
            "Rejected connections detected — a host may have a stale token — rotate it and re-run setup."
        )
        XCTAssertEqual(
            hint(ClaudeRemoteRejectionTally.Snapshot(missingToken: 1, unknownToken: 1)),
            "Rejected connections detected — a host may have an outdated plugin or a stale token."
        )
        XCTAssertEqual(
            hint(ClaudeRemoteRejectionTally.Snapshot(malformedAuthorization: 1)),
            "Rejected connections detected — a host may have a malformed authorization header."
        )
        for snapshot in [
            ClaudeRemoteRejectionTally.Snapshot(missingToken: 1),
            ClaudeRemoteRejectionTally.Snapshot(unknownToken: 1),
            ClaudeRemoteRejectionTally.Snapshot(missingToken: 1, unknownToken: 1),
            ClaudeRemoteRejectionTally.Snapshot(malformedAuthorization: 1),
        ] {
            XCTAssertLessThan(hint(snapshot)?.count ?? .max, 110)
        }
    }

    func testAModelWithNoListenerNeverInventsAHint() {
        let model = makeModel(registry: nil, listener: nil)
        model.refreshRejectionHint()
        XCTAssertNil(model.rejectionHint)
    }

    func testAnUnreadableRegistryDisablesTheRemoteSurfaceRatherThanFailingSilently() {
        // registry == nil is how AppDelegate reports "the host file exists but
        // could not be read". Offering an Enroll button that cannot work would
        // be worse than saying so.
        let model = makeModel(registry: nil, listener: nil)
        XCTAssertFalse(model.isRemoteAvailable)
        XCTAssertTrue(model.hosts.isEmpty)
    }
}
