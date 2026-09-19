import Foundation
import Synchronization
import XCTest
@testable import localvoxtral

/// A host store in memory, so no test here touches a real host list.
private final class MemoryStore: ClaudeRemoteHostStoreIO {
    private let contents = Mutex<[String: Data]>([:])
    func read(from url: URL) throws -> Data? { contents.withLock { $0[url.path] } }
    func write(_ data: Data, to url: URL) throws { contents.withLock { $0[url.path] = data } }
}

/// No-op plugin service: the import path never reaches the plugin, and the
/// stub keeps the model from needing a `claude` install to construct.
private final class StubPluginService: ClaudePluginInstalling {
    func installPlugin() throws {}
    func updatePlugin() throws {}
    func updateInstalledPlugin() throws {}
    func uninstallPlugin() throws {}
}

/// A listener that binds nothing, so the suite never opens the real port.
@MainActor
private final class StubListener: ClaudeRemoteListenerControlling {
    private let hosts: ClaudeRemoteHostRegistry
    var isListening = false
    var boundPort: UInt16 = 8473
    var rejectionSnapshot = ClaudeRemoteRejectionTally.Snapshot()

    init(hosts: ClaudeRemoteHostRegistry) {
        self.hosts = hosts
    }

    func reconcile() throws {
        isListening = hosts.hasActiveHosts
    }
}

/// File scope, not nested in the @MainActor test class: the fixture builders
/// are called from inside @Sendable seam closures, which must not capture an
/// actor-isolated self.
private func machine(
    _ id: String, label: String, target: String, enabled: Bool = true
) -> HerdrMachineProfile {
    HerdrMachineProfile(
        id: id, label: label, target: target, session: "default", enabled: enabled
    )
}

private func catalog(_ profiles: [HerdrMachineProfile]) -> HerdrMachineCatalogReading {
    .catalog(HerdrMachineCatalog(profiles: profiles, selectedProfileID: nil))
}

/// Saved herdr machines as an enrollment source (issue #288, Part A):
/// candidate derivation, ordering, the unreadable/absent readings, and the
/// Import… action reaching the typed form's consent-gated enrollment.
@MainActor
final class HerdrMachineImportTests: XCTestCase {
    private func makeRegistry() throws -> ClaudeRemoteHostRegistry {
        try ClaudeRemoteHostRegistry(
            fileURL: URL(fileURLWithPath: "/tmp/lvx-herdr-import-test/hosts.json"),
            io: MemoryStore(),
            now: { Date(timeIntervalSince1970: 1_000_000) }
        )
    }

    private func makeModel(
        registry: ClaudeRemoteHostRegistry?,
        listener: (any ClaudeRemoteListenerControlling)? = nil,
        catalogReading: @escaping @Sendable () -> HerdrMachineCatalogReading = { .absent }
    ) -> ClaudeIntegrationSettingsModel {
        ClaudeIntegrationSettingsModel(
            registry: registry,
            listener: listener,
            pluginService: { StubPluginService() },
            // Synchronous (AGENTS: no wall-clock, no detached-task races).
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
                do {
                    return ClaudeVerificationAttempt(checks: try body(), failure: nil)
                } catch {
                    return ClaudeVerificationAttempt(
                        checks: [], failure: ClaudeEnrollmentActionFailure(error)
                    )
                }
            },
            now: { Date(timeIntervalSince1970: 1_000_000) },
            herdrMachineCatalogReading: catalogReading
        )
    }

    private func candidates(
        of section: HerdrMachineImportSection
    ) throws -> [HerdrMachineImportCandidate] {
        guard case .candidates(let found) = section else {
            XCTFail("expected candidates, got \(section)")
            throw NSError(domain: "herdr-machine-import", code: 1)
        }
        return found
    }

    // MARK: - Candidate derivation

    /// Every status, from one catalog: exact-alias enrolled, plain-alias
    /// importable, both target forms the enrollment form cannot take, and
    /// herdr's own off switch.
    func testEveryStatusIsDerived() throws {
        let registry = try makeRegistry()
        let enrolled = try registry.enroll(label: "builder", sshHostAlias: "builder").host
        let reading = catalog([
            machine("a", label: "builder machine", target: "builder"),
            machine("b", label: "fresh", target: "build-host"),
            machine("c", label: "url", target: "ssh://dev@build.example.com:2222"),
            machine("d", label: "at host", target: "dev@build.example.com"),
            machine("e", label: "off", target: "build-host-2", enabled: false)
        ])
        let model = makeModel(registry: registry, catalogReading: { reading })

        let found = try candidates(of: model.herdrMachines)
        XCTAssertEqual(
            found.map(\.status),
            [
                .enrolled(hostID: enrolled.id),
                .importable,
                .needsAlias,
                .needsAlias,
                .disabled
            ]
        )
        // The profile rides along, unmangled.
        XCTAssertEqual(found.first?.profile.target, "builder")
    }

    /// Candidates keep the catalog's file order, not any sorted order.
    func testCandidatesFollowTheCatalogsFileOrder() throws {
        let reading = catalog([
            machine("c", label: "third saved", target: "gamma"),
            machine("a", label: "first saved", target: "alpha"),
            machine("b", label: "second saved", target: "beta")
        ])
        let model = makeModel(registry: try makeRegistry(), catalogReading: { reading })

        XCTAssertEqual(
            try candidates(of: model.herdrMachines).map(\.profile.id),
            ["c", "a", "b"]
        )
    }

    /// "Enrolled" is an EXACT alias match. Settings does not canonicalize a
    /// target with `ssh -G` — that comparison belongs to the join arm, at
    /// join time — so a target that merely names the same machine by another
    /// spelling is offered for import, not silently folded into the enrolled
    /// host.
    func testEnrolledRequiresAnExactAliasMatch() throws {
        let registry = try makeRegistry()
        _ = try registry.enroll(label: "builder", sshHostAlias: "builder").host
        let reading = catalog([
            machine("f", label: "same box", target: "build.example.com"),
            machine("g", label: "same box user", target: "dev@build.example.com")
        ])
        let model = makeModel(registry: registry, catalogReading: { reading })

        XCTAssertEqual(
            try candidates(of: model.herdrMachines).map(\.status),
            [.importable, .needsAlias]
        )
    }

    /// A revoked host never counts as enrolled: its credential is withdrawn,
    /// so the machine is importable again rather than silently skipped.
    func testARevokedHostDoesNotCountAsEnrolled() throws {
        let registry = try makeRegistry()
        let enrolled = try registry.enroll(label: "builder", sshHostAlias: "builder").host
        try registry.revoke(hostID: enrolled.id)
        let reading = catalog([machine("h", label: "back", target: "builder")])
        let model = makeModel(registry: registry, catalogReading: { reading })

        XCTAssertEqual(try candidates(of: model.herdrMachines).map(\.status), [.importable])
    }

    // MARK: - Unreadable and absent catalogs

    /// An unreadable catalog is one inline message's worth of fact — the
    /// section says `.unreadable`, never an alert and never a guessed list.
    func testAnUnreadableCatalogIsTheUnreadableSection() throws {
        let model = makeModel(registry: try makeRegistry(), catalogReading: { .unreadable })
        XCTAssertEqual(model.herdrMachines, .unreadable)
    }

    /// An absent catalog renders nothing at all: no empty-state row for a
    /// feature this user does not use.
    func testAnAbsentCatalogIsNoSectionAtAll() throws {
        let model = makeModel(registry: try makeRegistry(), catalogReading: { .absent })
        XCTAssertEqual(model.herdrMachines, .absent)
    }

    // MARK: - Import…

    /// Import pre-fills the typed form (alias = target, label = profile
    /// label) and runs the SAME consent-gated enrollment: the plan sheet is
    /// up with the right alias and label, the listener bound like any first
    /// enrollment, the form cleared — and nothing has run on any host until
    /// the sheet's Set Up.
    func testImportPrefillsTheFormAndRunsTheTypedFormsEnrollmentFlow() async throws {
        let registry = try makeRegistry()
        let listener = StubListener(hosts: registry)
        let reading = catalog([machine("i", label: "build machine", target: "builder")])
        let model = makeModel(registry: registry, listener: listener, catalogReading: { reading })
        let candidate = try candidates(of: model.herdrMachines)[0]

        await model.importHerdrMachine(candidate)

        let plan = try XCTUnwrap(model.presentedPlan)
        XCTAssertEqual(plan.sshHostAlias, "builder")
        XCTAssertEqual(plan.host.label, "build machine")
        XCTAssertEqual(plan.host.sshHostAlias, "builder")
        // The same 0→1 listener transition the typed form's enroll performs.
        XCTAssertTrue(listener.isListening)
        // enroll()'s own cleanup, unchanged.
        XCTAssertEqual(model.enrollLabel, "")
        XCTAssertEqual(model.enrollSSHAlias, "")
        // Consent-gated: the sheet is up, but no step has run anywhere.
        XCTAssertNil(model.setupRun)
        XCTAssertTrue(model.enrollmentStepStatuses.isEmpty)
        // The same refresh re-derived the row as enrolled.
        XCTAssertEqual(
            try candidates(of: model.herdrMachines).first?.status,
            .enrolled(hostID: plan.host.id)
        )
    }

    /// A stale `.importable` snapshot must not enroll a second host: the alias
    /// was enrolled by hand through the typed form's `enroll()` after the
    /// snapshot was taken, so the import re-derives freshness and refuses —
    /// host count unchanged, no new plan.
    func testStaleSnapshotAfterHandEnrollRefusesSecondHost() async throws {
        let registry = try makeRegistry()
        let reading = catalog([machine("m", label: "build machine", target: "builder")])
        let model = makeModel(
            registry: registry,
            listener: StubListener(hosts: registry),
            catalogReading: { reading }
        )
        let stale = try candidates(of: model.herdrMachines)[0]
        XCTAssertEqual(stale.status, .importable)

        // The hand enrollment the snapshot predates.
        model.enrollLabel = "hand enrolled"
        model.enrollSSHAlias = "builder"
        await model.enroll()
        XCTAssertNotNil(model.presentedPlan)
        model.dismissPlan()

        await model.importHerdrMachine(stale)

        XCTAssertEqual(registry.hosts().count, 1)
        XCTAssertNil(model.presentedPlan)
    }

    /// Two rapid `Import…` taps capture the same `.importable` snapshot; the
    /// second must refuse — exactly one host enrolled, one plan presented.
    func testBackToBackImportsEnrollExactlyOneHost() async throws {
        let registry = try makeRegistry()
        let reading = catalog([machine("n", label: "build machine", target: "builder")])
        let model = makeModel(
            registry: registry,
            listener: StubListener(hosts: registry),
            catalogReading: { reading }
        )
        let candidate = try candidates(of: model.herdrMachines)[0]

        await model.importHerdrMachine(candidate)
        let firstPlan = try XCTUnwrap(model.presentedPlan)
        await model.importHerdrMachine(candidate)

        XCTAssertEqual(registry.hosts().count, 1)
        XCTAssertEqual(model.presentedPlan?.host.id, firstPlan.host.id)
    }

    /// Only freshly derived non-importable rows refuse here: an enrolled,
    /// needsAlias, or disabled row must not enroll a host through this path.
    /// (The stale-`.importable` case is covered by
    /// `testStaleSnapshotAfterHandEnrollRefusesSecondHost`.)
    func testFreshlyDerivedNonImportableRowsRefuse() async throws {
        let registry = try makeRegistry()
        let handEnrolled = try registry.enroll(label: "builder", sshHostAlias: "builder").host
        let reading = catalog([
            machine("j", label: "already here", target: "builder"),
            machine("k", label: "needs alias", target: "dev@build.example.com"),
            machine("l", label: "off", target: "build-host-2", enabled: false)
        ])
        let model = makeModel(
            registry: registry,
            listener: StubListener(hosts: registry),
            catalogReading: { reading }
        )

        for candidate in try candidates(of: model.herdrMachines) {
            await model.importHerdrMachine(candidate)
        }

        XCTAssertNil(model.presentedPlan)
        XCTAssertEqual(model.hosts.map(\.id), [handEnrolled.id])
        XCTAssertEqual(model.enrollLabel, "")
        XCTAssertEqual(model.enrollSSHAlias, "")
    }

    /// An empty catalog renders nothing: zero profiles is "no machines
    /// saved", not a header with zero rows.
    func testEmptyCatalogRendersNothing() throws {
        let model = makeModel(registry: try makeRegistry(), catalogReading: { catalog([]) })
        XCTAssertEqual(model.herdrMachines, .absent)
    }

    /// The needsAlias row's one sentence is pinned: it must not promise an
    /// import the row does not offer.
    func testNeedsAliasSentenceIsPinned() {
        XCTAssertEqual(
            HerdrMachineImportStatus.needsAlias.sentence,
            "Add an SSH config alias for it first."
        )
        XCTAssertNil(HerdrMachineImportStatus.importable.sentence)
    }

    /// The sidebar's fixed dot meanings applied to import rows: green for
    /// already enrolled, yellow for the row the pane can act on, grey for
    /// the rows it cannot.
    func testImportStatusDotMapping() {
        XCTAssertEqual(HerdrMachineImportStatus.enrolled(hostID: "h").dot, .green)
        XCTAssertEqual(HerdrMachineImportStatus.importable.dot, .yellow)
        XCTAssertEqual(HerdrMachineImportStatus.needsAlias.dot, .grey)
        XCTAssertEqual(HerdrMachineImportStatus.disabled.dot, .grey)
    }
}
