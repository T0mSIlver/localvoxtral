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

    init(hosts: ClaudeRemoteHostRegistry) {
        self.hosts = hosts
    }

    func reconcile() throws {
        reconcileCount += 1
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

    var readCount: Int { reads.withLock { $0 } }
    var writeCount: Int { writes.withLock { $0 } }

    func readState() throws -> ClaudeRemoteSSHConfigState {
        reads.withLock { $0 += 1 }
        return ClaudeRemoteSSHConfigState(
            directoryExists: true,
            configData: nil,
            configPermissions: nil
        )
    }

    func createSSHDirectory(permissions _: UInt16) throws {}

    func atomicWriteConfig(_ data: Data, permissions: UInt16) throws {
        XCTAssertFalse(data.isEmpty)
        XCTAssertEqual(permissions, 0o600)
        writes.withLock { $0 += 1 }
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
        enrollmentService: ClaudeRemoteEnrollmentService = ClaudeRemoteEnrollmentService()
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
            performVerificationAsync: { body in
                do {
                    return ClaudeVerificationAttempt(checks: try body(), failure: nil)
                } catch {
                    return ClaudeVerificationAttempt(
                        checks: [],
                        failure: ClaudeEnrollmentActionFailure(error)
                    )
                }
            }
        )
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
            }
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

    // MARK: Step 3 — in-app verification

    func testCheckSetupPublishesInterpretedVerdictsAndNeedsNoConfirmation() async throws {
        let registry = try makeRegistry()
        let calls = Mutex<[ClaudeRemoteEnrollmentService.Invocation]>([])
        let index = Mutex(0)
        let service = ClaudeRemoteEnrollmentService(runner: { invocation in
            calls.withLock { $0.append(invocation) }
            let call = index.withLock { value -> Int in
                defer { value += 1 }
                return value
            }
            return call == 0
                ? .init(exitCode: 0, message: "401")
                : .init(exitCode: 0, message: "localvoxtral-remote@localvoxtral")
        })
        let model = makeModel(
            registry: registry,
            listener: StubListener(hosts: registry),
            enrollmentService: service
        )
        model.enrollLabel = "buildhost"
        model.enrollSSHAlias = "builder"
        await model.enroll()
        XCTAssertTrue(model.verificationChecks.isEmpty, "a sheet must not spawn ssh on opening")

        await model.runVerification()

        // Read-only, so there is deliberately no confirmation gate here — the
        // gate exists for actions that WRITE.
        XCTAssertNil(model.enrollmentConfirmation)
        XCTAssertEqual(model.verificationChecks.map(\.passed), [true, true])
        XCTAssertNil(model.alert, "all-pass must not raise an alert")
        XCTAssertEqual(calls.withLock { $0 }.count, 2)
        XCTAssertFalse(model.isPerformingVerification)
    }

    func testAFailedCheckIsAShortLineInTheSheetAndTheOutputGoesToTheAlert() async throws {
        let registry = try makeRegistry()
        let noise = String(repeating: "ssh debug line\n", count: 100)
        let service = ClaudeRemoteEnrollmentService(runner: { _ in
            .init(exitCode: 255, message: noise)
        })
        let model = makeModel(
            registry: registry,
            listener: StubListener(hosts: registry),
            enrollmentService: service
        )
        model.enrollLabel = "buildhost"
        model.enrollSSHAlias = "builder"
        await model.enroll()

        await model.runVerification()

        let tunnel = try XCTUnwrap(model.verificationChecks.first { $0.kind == .tunnel })
        XCTAssertFalse(tunnel.passed)
        // Owner rule: the pane/sheet gets one sentence, the log and the alert
        // get the pages of output.
        XCTAssertLessThan(tunnel.summary.count, 80)
        XCTAssertFalse(tunnel.summary.contains("ssh debug line"))
        XCTAssertTrue(model.alert?.detail.contains("ssh debug line") ?? false)
    }

    /// `claude plugin list` on the host may print the plugin's configured
    /// token, and this detail goes to an alert and to the log. Verification
    /// sends no credential; that does not mean none can come back.
    func testHostOutputThatEchoesTheTokenIsRedactedBeforeItReachesTheAlert() async throws {
        let registry = try makeRegistry()
        let tokenBox = Mutex("")
        let service = ClaudeRemoteEnrollmentService(runner: { _ in
            .init(exitCode: 0, message: "config: token=\(tokenBox.withLock { $0 })")
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
        tokenBox.withLock { $0 = token }

        await model.runVerification()

        for check in model.verificationChecks {
            XCTAssertFalse(check.detail.contains(token))
            XCTAssertTrue(check.detail.contains(ClaudeRemoteTokenRedaction.placeholder))
        }
        XCTAssertFalse(model.alert?.detail.contains(token) ?? false)
    }

    func testVerificationProbesThePortTheSnippetActuallyForwards() async throws {
        let registry = try makeRegistry()
        let calls = Mutex<[ClaudeRemoteEnrollmentService.Invocation]>([])
        let service = ClaudeRemoteEnrollmentService(runner: { invocation in
            calls.withLock { $0.append(invocation) }
            return .init(exitCode: 0, message: "401")
        })
        let listener = StubListener(hosts: registry)
        listener.boundPort = 8473
        let model = makeModel(registry: registry, listener: listener, enrollmentService: service)
        model.enrollLabel = "buildhost"
        model.enrollSSHAlias = "builder"
        await model.enroll()
        let presentation = try XCTUnwrap(model.presentedPlan)
        XCTAssertEqual(presentation.port, 8473)
        // A listener that moved after the plan was generated must not make the
        // check answer about a different port than the config the user pasted.
        listener.boundPort = 9999

        await model.runVerification()

        let script = String(decoding: calls.withLock { $0 }[0].standardInput, as: UTF8.self)
        XCTAssertTrue(script.contains("127.0.0.1:8473"))
        XCTAssertFalse(script.contains("9999"))
    }

    func testAnEnrollmentActionAndACheckCannotInterleave() async throws {
        let registry = try makeRegistry()
        let (gate, releaseGate) = AsyncStream.makeStream(of: Void.self)
        let service = ClaudeRemoteEnrollmentService(runner: { _ in
            .init(exitCode: 0, message: "401")
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
                do {
                    return ClaudeEnrollmentActionAttempt(steps: try body(), failure: nil)
                } catch {
                    return ClaudeEnrollmentActionAttempt(
                        steps: [], failure: ClaudeEnrollmentActionFailure(error)
                    )
                }
            },
            performVerificationAsync: { body in
                // Park until released — cooperative yields only, no wall-clock.
                var latch = gate.makeAsyncIterator()
                _ = await latch.next()
                do {
                    return ClaudeVerificationAttempt(checks: try body(), failure: nil)
                } catch {
                    return ClaudeVerificationAttempt(
                        checks: [], failure: ClaudeEnrollmentActionFailure(error)
                    )
                }
            }
        )
        model.enrollLabel = "buildhost"
        model.enrollSSHAlias = "builder"
        await model.enroll()

        let inFlight = Task { await model.runVerification() }
        while !model.isPerformingVerification { await Task.yield() }
        XCTAssertTrue(model.isEnrollmentBusy)

        // Both write paths must refuse while a check is running: they share the
        // sheet, the seams, and the result rows.
        model.requestSSHConfigInsertion()
        model.requestRemoteSetup()
        XCTAssertNil(model.enrollmentConfirmation)
        await model.runVerification()

        releaseGate.yield(())
        releaseGate.finish()
        await inFlight.value
        XCTAssertEqual(model.verificationChecks.count, 2)
    }

    func testALateCheckResultFromBeforeARotationNeverSurfacesUnderTheNewToken() async throws {
        let registry = try makeRegistry()
        let (gate, releaseGate) = AsyncStream.makeStream(of: Void.self)
        let service = ClaudeRemoteEnrollmentService(runner: { _ in
            .init(exitCode: 0, message: "401")
        })
        let model = ClaudeIntegrationSettingsModel(
            registry: registry,
            listener: StubListener(hosts: registry),
            pluginService: { StubPluginService() },
            enrollmentService: service,
            performAsync: { _ in nil },
            performEnrollmentAsync: { _ in ClaudeEnrollmentActionAttempt(steps: [], failure: nil) },
            performVerificationAsync: { body in
                var latch = gate.makeAsyncIterator()
                _ = await latch.next()
                do {
                    return ClaudeVerificationAttempt(checks: try body(), failure: nil)
                } catch {
                    return ClaudeVerificationAttempt(
                        checks: [], failure: ClaudeEnrollmentActionFailure(error)
                    )
                }
            }
        )
        model.enrollLabel = "buildhost"
        model.enrollSSHAlias = "builder"
        await model.enroll()
        let hostID = try XCTUnwrap(model.presentedPlan).host.id

        let inFlight = Task { await model.runVerification() }
        while !model.isPerformingVerification { await Task.yield() }

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
            model.verificationChecks.isEmpty,
            "a check from the previous generation must not render under the rotation sheet"
        )
    }

    func testDismissingTheSheetClearsTheVerdicts() async throws {
        let registry = try makeRegistry()
        let service = ClaudeRemoteEnrollmentService(runner: { _ in .init(exitCode: 0, message: "401") })
        let model = makeModel(
            registry: registry,
            listener: StubListener(hosts: registry),
            enrollmentService: service
        )
        model.enrollLabel = "buildhost"
        model.enrollSSHAlias = "builder"
        await model.enroll()
        await model.runVerification()
        XCTAssertFalse(model.verificationChecks.isEmpty)

        model.dismissPlan()

        XCTAssertTrue(model.verificationChecks.isEmpty)
    }

    func testCheckSetupIsUnavailableWithoutARunnerAndSaysSo() async throws {
        let registry = try makeRegistry()
        let model = makeModel(
            registry: registry,
            listener: StubListener(hosts: registry),
            enrollmentService: ClaudeRemoteEnrollmentService()
        )
        model.enrollLabel = "buildhost"
        model.enrollSSHAlias = "builder"
        await model.enroll()

        await model.runVerification()

        XCTAssertTrue(model.verificationChecks.isEmpty)
        XCTAssertEqual(model.alert?.detail, "Checking the setup is not available in this build.")
    }

    // MARK: Screenshot preview

    /// The preview sheet exists to be photographed. It must be incapable of
    /// touching the registry, `~/.ssh/config`, or an ssh process — so both
    /// mutating seams fail the test if they are reached at all.
    func testThePreviewSheetCannotReachTheRunnerOrTheFilesystem() async throws {
        let registry = try makeRegistry()
        let fileSystem = RecordingSSHConfigFileSystem()
        let service = ClaudeRemoteEnrollmentService(
            runner: { _ in
                XCTFail("a preview must never spawn ssh")
                return .init(exitCode: 0, message: "")
            },
            sshConfigFileSystem: fileSystem
        )
        let model = makeModel(
            registry: registry,
            listener: StubListener(hosts: registry),
            enrollmentService: service
        )

        model.presentPreviewPlan()

        let presentation = try XCTUnwrap(model.presentedPlan)
        XCTAssertTrue(presentation.isPreview)
        XCTAssertEqual(presentation.host.label, "build-host")
        XCTAssertTrue(presentation.token.hasPrefix("lvx-preview-"), "a preview token must read as fake")
        XCTAssertTrue(model.hosts.isEmpty, "a preview must not enroll anything")
        XCTAssertNil(
            registry.authenticate(token: presentation.token),
            "the sample credential must authenticate nothing"
        )

        model.requestSSHConfigInsertion()
        model.requestRemoteSetup()
        await model.confirmEnrollmentAction()
        await model.runVerification()

        XCTAssertNil(model.enrollmentConfirmation)
        XCTAssertTrue(model.enrollmentStepStatuses.isEmpty)
        XCTAssertTrue(model.verificationChecks.isEmpty)
        XCTAssertEqual(fileSystem.readCount, 0)
        XCTAssertEqual(fileSystem.writeCount, 0)
    }

    func testThePreviewNeverReplacesARealSheet() async throws {
        let registry = try makeRegistry()
        let model = makeModel(registry: registry, listener: StubListener(hosts: registry))
        model.enrollLabel = "buildhost"
        model.enrollSSHAlias = "builder"
        await model.enroll()
        let real = try XCTUnwrap(model.presentedPlan)

        model.presentPreviewPlan()

        XCTAssertEqual(model.presentedPlan, real)
        XCTAssertFalse(try XCTUnwrap(model.presentedPlan).isPreview)
    }

    func testThePreviewIsOffUnlessTheDebugDefaultIsArmed() throws {
        let suiteName = "lvx-preview-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertFalse(ClaudeIntegrationSettingsModel.isEnrollmentSheetPreviewArmed(defaults: defaults))
        defaults.set(true, forKey: ClaudeIntegrationSettingsModel.enrollmentSheetPreviewDefaultsKey)
        XCTAssertTrue(ClaudeIntegrationSettingsModel.isEnrollmentSheetPreviewArmed(defaults: defaults))
        // `debug.` prefixed: not a product preference, never in the Settings UI.
        XCTAssertTrue(
            ClaudeIntegrationSettingsModel.enrollmentSheetPreviewDefaultsKey.hasPrefix("debug.")
        )
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
