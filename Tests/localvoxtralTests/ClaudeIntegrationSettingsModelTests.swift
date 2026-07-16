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
        plugin: StubPluginService = StubPluginService()
    ) -> ClaudeIntegrationSettingsModel {
        ClaudeIntegrationSettingsModel(
            registry: registry,
            listener: listener,
            pluginService: { plugin },
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

    func testAnUnreadableRegistryDisablesTheRemoteSurfaceRatherThanFailingSilently() {
        // registry == nil is how AppDelegate reports "the host file exists but
        // could not be read". Offering an Enroll button that cannot work would
        // be worse than saying so.
        let model = makeModel(registry: nil, listener: nil)
        XCTAssertFalse(model.isRemoteAvailable)
        XCTAssertTrue(model.hosts.isEmpty)
    }
}
