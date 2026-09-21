import Foundation
import Synchronization
import XCTest
@testable import localvoxtral

/// The field capture that named this bug: an installed, enabled plugin whose
/// marketplace path had been swept from `/private/tmp` (2026-09-21).
private let failedToLoadListing = """
[{"id":"localvoxtral@localvoxtral","version":"1.1.0","scope":"user","enabled":true,\
"installPath":"/Users/tom/.claude/plugins/cache/localvoxtral/localvoxtral/1.1.0",\
"errors":["Marketplace localvoxtral failed to load: cache-miss"],\
"errorDetails":[{"type":"marketplace-load-failed","marketplace":"localvoxtral"}]}]
"""

/// `claude plugin marketplace list --json` from the same machine.
private let marketplaceListing = """
[{"name":"claude-plugins-official","source":"github","repo":"anthropics/claude-plugins-official",\
"installLocation":"/Users/tom/.claude/plugins/marketplaces/claude-plugins-official"},\
{"name":"localvoxtral","source":"directory",\
"path":"/private/tmp/localvoxtral-try.Wfehwb/extracted/localvoxtral.app/Contents/Resources/claude-code-marketplace",\
"installLocation":"/private/tmp/localvoxtral-try.Wfehwb/extracted/localvoxtral.app/Contents/Resources/claude-code-marketplace"}]
"""

// MARK: - The mirror itself

final class ClaudeMarketplaceMirrorTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lv-mirror-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// A marketplace-shaped source tree: the manifest Claude Code reads plus a
    /// hook script, so a change to either is a change to what runs.
    private func makeSource(hook: String = "publish\n") throws -> URL {
        let source = root.appendingPathComponent("bundle")
        let manifest = source.appendingPathComponent(".claude-plugin")
        let hooks = source.appendingPathComponent("plugins/localvoxtral/hooks")
        try FileManager.default.createDirectory(at: manifest, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: manifest.appendingPathComponent("marketplace.json"))
        try Data(hook.utf8).write(to: hooks.appendingPathComponent("publish.sh"))
        return source
    }

    private func mirrorURL() -> URL { root.appendingPathComponent("mirror") }

    func testFirstRefreshCopiesTheWholeTree() throws {
        let source = try makeSource()
        XCTAssertEqual(try ClaudeMarketplaceMirror.refresh(source: source, mirrorURL: mirrorURL()), .created)

        let copiedHook = mirrorURL().appendingPathComponent("plugins/localvoxtral/hooks/publish.sh")
        XCTAssertEqual(try String(contentsOf: copiedHook, encoding: .utf8), "publish\n")
        XCTAssertTrue(ClaudePluginAssets.isMarketplace(mirrorURL()))
        XCTAssertEqual(ClaudeMarketplaceMirror.usableURL(mirrorURL: mirrorURL()), mirrorURL())
    }

    func testIdenticalSourceIsNotCopiedAgain() throws {
        let source = try makeSource()
        _ = try ClaudeMarketplaceMirror.refresh(source: source, mirrorURL: mirrorURL())
        XCTAssertEqual(
            try ClaudeMarketplaceMirror.refresh(source: source, mirrorURL: mirrorURL()),
            .unchanged
        )
    }

    func testChangedHookContentRefreshesTheMirror() throws {
        let source = try makeSource()
        _ = try ClaudeMarketplaceMirror.refresh(source: source, mirrorURL: mirrorURL())
        // The same version of the plugin can ship a different shim: content,
        // not a version number, decides whether the mirror is current.
        let hook = source.appendingPathComponent("plugins/localvoxtral/hooks/publish.sh")
        try Data("publish --new\n".utf8).write(to: hook)

        XCTAssertEqual(
            try ClaudeMarketplaceMirror.refresh(source: source, mirrorURL: mirrorURL()),
            .updated
        )
        let copied = mirrorURL().appendingPathComponent("plugins/localvoxtral/hooks/publish.sh")
        XCTAssertEqual(try String(contentsOf: copied, encoding: .utf8), "publish --new\n")
    }

    func testRenamingAFileChangesTheDigest() throws {
        let source = try makeSource()
        let before = try ClaudeMarketplaceMirror.digest(of: source)
        let hooks = source.appendingPathComponent("plugins/localvoxtral/hooks")
        try FileManager.default.moveItem(
            at: hooks.appendingPathComponent("publish.sh"),
            to: hooks.appendingPathComponent("publish-v2.sh")
        )
        // Same bytes, different name — and the name is what the manifest execs.
        XCTAssertNotEqual(try ClaudeMarketplaceMirror.digest(of: source), before)
    }

    func testRefreshLeavesNoStagingTreeBehind() throws {
        let source = try makeSource()
        _ = try ClaudeMarketplaceMirror.refresh(source: source, mirrorURL: mirrorURL())
        try Data("publish --new\n".utf8).write(
            to: source.appendingPathComponent("plugins/localvoxtral/hooks/publish.sh")
        )
        _ = try ClaudeMarketplaceMirror.refresh(source: source, mirrorURL: mirrorURL())

        let siblings = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertEqual(
            siblings.filter { $0.hasPrefix(ClaudeMarketplaceMirror.stagingPrefix) },
            []
        )
    }

    func testAFileAtTheMirrorPathIsReplacedRatherThanFailingForever() throws {
        let source = try makeSource()
        try Data("not a marketplace".utf8).write(to: mirrorURL())
        // Left to fail, every launch would throw here, `usableURL()` would stay
        // nil, and the registration would fall back to a bundle path — the rot
        // this whole file exists to end.
        XCTAssertEqual(try ClaudeMarketplaceMirror.refresh(source: source, mirrorURL: mirrorURL()), .created)
        XCTAssertTrue(ClaudePluginAssets.isMarketplace(mirrorURL()))
    }

    func testDigestSeparatesNamesFromContents() throws {
        // Unframed concatenation would hash these two trees identically, and
        // the mirror would serve stale bytes forever.
        let left = root.appendingPathComponent("left")
        let right = root.appendingPathComponent("right")
        try FileManager.default.createDirectory(at: left, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: right, withIntermediateDirectories: true)
        try Data("bc".utf8).write(to: left.appendingPathComponent("a"))
        try Data("c".utf8).write(to: right.appendingPathComponent("ab"))

        XCTAssertNotEqual(
            try ClaudeMarketplaceMirror.digest(of: left),
            try ClaudeMarketplaceMirror.digest(of: right)
        )
    }

    func testAnEmptyFileIsNotADirectoryOfTheSameName() throws {
        let left = root.appendingPathComponent("l")
        let right = root.appendingPathComponent("r")
        try FileManager.default.createDirectory(at: left, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: right.appendingPathComponent("x"), withIntermediateDirectories: true
        )
        try Data().write(to: left.appendingPathComponent("x"))

        XCTAssertNotEqual(
            try ClaudeMarketplaceMirror.digest(of: left),
            try ClaudeMarketplaceMirror.digest(of: right)
        )
    }

    func testAMirrorWithoutAManifestIsNotUsable() throws {
        try FileManager.default.createDirectory(at: mirrorURL(), withIntermediateDirectories: true)
        // A half-deleted mirror must send the caller back to the bundle rather
        // than registering a path that fails at session start.
        XCTAssertNil(ClaudeMarketplaceMirror.usableURL(mirrorURL: mirrorURL()))
    }

    func testTheMirrorSitsBesideThePublisherLink() {
        // Both are the app's own state, and the shim's hardcoded publisher
        // path pins that directory — a mirror elsewhere would be a second
        // place to look for the same thing.
        XCTAssertEqual(
            URL(fileURLWithPath: ClaudeMarketplaceMirror.homeRelativePath).deletingLastPathComponent(),
            URL(fileURLWithPath: ClaudePublisherPointer.homeRelativePath).deletingLastPathComponent()
        )
    }
}

// MARK: - Reading what Claude Code says

final class ClaudeMarketplaceRegistrationTests: XCTestCase {
    func testAPluginThatLoadsNothingIsNotInstalled() {
        let status = ClaudePluginStatus.derive(listOutput: failedToLoadListing, bundledVersion: "1.1.0")
        XCTAssertEqual(status, .failedToLoad(version: "1.1.0"))
        XCTAssertEqual(status.sentence, "Installed, but not loading.")
        XCTAssertEqual(status.primaryAction, .repair)
        XCTAssertTrue(status.offersRemove)
        XCTAssertEqual(IntegrationsSidebarStatus.claudeDot(pluginStatus: status), .yellow)
    }

    func testAnUnrelatedErrorDoesNotReadAsAMarketplaceFailure() {
        let listing = """
        [{"id":"localvoxtral@localvoxtral","version":"1.1.0","scope":"user","enabled":true,\
        "errorDetails":[{"type":"hook-timeout"}]}]
        """
        // Only the marketplace failure means "loading nothing"; everything
        // else is a healthy install with a bad day.
        XCTAssertEqual(
            ClaudePluginStatus.derive(listOutput: listing, bundledVersion: "1.1.0"),
            .installed(version: "1.1.0")
        )
    }

    func testAHealthyListingIsUnchanged() {
        let listing = """
        [{"id":"localvoxtral@localvoxtral","version":"1.1.0","scope":"user","enabled":true}]
        """
        XCTAssertEqual(
            ClaudePluginStatus.derive(listOutput: listing, bundledVersion: "1.1.0"),
            .installed(version: "1.1.0")
        )
    }

    func testRegisteredPathIsReadFromTheMarketplaceListing() {
        XCTAssertEqual(
            ClaudePluginListing.registeredMarketplacePath(in: marketplaceListing),
            "/private/tmp/localvoxtral-try.Wfehwb/extracted/localvoxtral.app/Contents/Resources/claude-code-marketplace"
        )
    }

    func testAGitHubSourceAndAnAbsentNameHaveNoPath() {
        XCTAssertNil(
            ClaudePluginListing.registeredMarketplacePath(in: marketplaceListing, name: "claude-plugins-official")
        )
        XCTAssertNil(ClaudePluginListing.registeredMarketplacePath(in: marketplaceListing, name: "nobody"))
        XCTAssertNil(ClaudePluginListing.registeredMarketplacePath(in: "not json"))
    }
}

// MARK: - When the app re-points the registration

final class ClaudeMarketplaceRepairDecisionTests: XCTestCase {
    private func needsRepair(
        _ status: ClaudePluginStatus,
        registered: String?,
        desired: String? = "/Users/t/Library/Application Support/localvoxtral/claude/marketplace"
    ) -> Bool {
        ClaudeIntegrationSettingsModel.marketplaceNeedsRepair(
            status: status,
            registeredPath: registered,
            desiredPath: desired,
            // Deterministic: these paths must not be looked up on the machine
            // running the suite. Existence is varied explicitly where it is
            // the thing under test.
            registrationCanRot: {
                ClaudeIntegrationSettingsModel.registrationCanRot(path: $0, directoryExists: { _ in true })
            }
        )
    }

    func testAPluginThatLoadsNothingIsRepairedWhateverThePathSays() {
        XCTAssertTrue(needsRepair(.failedToLoad(version: "1.1.0"), registered: nil))
        XCTAssertTrue(
            needsRepair(
                .failedToLoad(version: "1.1.0"),
                registered: "/Users/t/Library/Application Support/localvoxtral/claude/marketplace"
            )
        )
    }

    func testARegistrationInsideAnAppBundleIsRepaired() {
        XCTAssertTrue(
            needsRepair(
                .installed(version: "1.1.0"),
                registered: "/private/tmp/localvoxtral-try.Wfehwb/extracted/localvoxtral.app/Contents/Resources/claude-code-marketplace"
            )
        )
    }

    func testOurOwnPathIsLeftAlone() {
        XCTAssertFalse(
            needsRepair(
                .installed(version: "1.1.0"),
                registered: "/Users/t/Library/Application Support/localvoxtral/claude/marketplace"
            )
        )
    }

    func testTwoNamesForOneRealDirectoryAreNotADisagreement() throws {
        // macOS reaches /tmp through a symlink to /private/tmp, and Claude
        // Code prints the resolved form of what it was handed. Comparing the
        // strings would re-run the command on every single launch, forever.
        let directory = URL(fileURLWithPath: "/tmp/lv-marketplace-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let resolved = "/private" + directory.path

        XCTAssertTrue(
            ClaudeIntegrationSettingsModel.pathsAreTheSameDirectory(directory.path, resolved)
        )
        XCTAssertFalse(
            needsRepair(.installed(version: "1.1.0"), registered: resolved, desired: directory.path)
        )
    }

    func testADeveloperCheckoutIsLeftAlone() {
        // `claude plugin marketplace add ./integrations/claude-code` is
        // documented in the plugin README and is how anyone edits the shim.
        // It exists, it works, and it is not ours to take.
        XCTAssertFalse(
            ClaudeIntegrationSettingsModel.marketplaceNeedsRepair(
                status: .installed(version: "1.1.0"),
                registeredPath: "/Users/t/src/localvoxtral/integrations/claude-code",
                desiredPath: "/Users/t/Library/Application Support/localvoxtral/claude/marketplace",
                registrationCanRot: { ClaudeIntegrationSettingsModel.registrationCanRot(path: $0, directoryExists: { _ in true }) }
            )
        )
    }

    func testAPathInsideAnAppBundleIsTakenOverBeforeItRots() {
        // Still readable today; gone the moment the build is swept, the app is
        // replaced, or the user drags it to the Trash.
        XCTAssertTrue(
            ClaudeIntegrationSettingsModel.registrationCanRot(
                path: "/private/tmp/localvoxtral-try.Wfehwb/extracted/localvoxtral.app/Contents/Resources/claude-code-marketplace",
                directoryExists: { _ in true }
            )
        )
        XCTAssertTrue(
            ClaudeIntegrationSettingsModel.registrationCanRot(
                path: "/Applications/localvoxtral.app/Contents/Resources/claude-code-marketplace",
                directoryExists: { _ in true }
            )
        )
    }

    func testAPathThatIsAlreadyGoneIsTakenOver() {
        XCTAssertTrue(
            ClaudeIntegrationSettingsModel.registrationCanRot(
                path: "/private/tmp/swept/claude-code-marketplace",
                directoryExists: { _ in false }
            )
        )
    }

    func testAPathWeCouldNotReadIsNeverATrigger() {
        XCTAssertFalse(needsRepair(.installed(version: "1.1.0"), registered: nil))
        XCTAssertFalse(needsRepair(.installed(version: "1.1.0"), registered: "/anywhere", desired: nil))
    }

    func testNothingInstalledAndNothingReadAreNeverRepaired() {
        XCTAssertFalse(needsRepair(.notInstalled, registered: "/private/tmp/gone"))
        XCTAssertFalse(needsRepair(.unknown, registered: "/private/tmp/gone"))
    }
}

// MARK: - The launch path

final class ClaudeMarketplaceLaunchRepairTests: XCTestCase {
    @MainActor
    private func makeModel(
        listing: String,
        marketplaces: String?,
        desired: @escaping @Sendable () -> String?,
        service: any ClaudePluginInstalling
    ) -> ClaudeIntegrationSettingsModel {
        ClaudeIntegrationSettingsModel(
            registry: nil,
            listener: nil,
            pluginService: { service },
            performAsync: { body in
                do {
                    try body()
                    return nil
                } catch {
                    return ClaudePluginActionFailure(error)
                }
            },
            fetchPluginListOutput: { listing },
            fetchMarketplaceListOutput: { marketplaces },
            desiredMarketplacePath: desired,
            bundledPluginVersion: "1.1.0"
        )
    }

    @MainActor
    private func makeModel(
        listing: String,
        marketplaces: String?,
        desired: String?,
        service: any ClaudePluginInstalling
    ) -> ClaudeIntegrationSettingsModel {
        makeModel(listing: listing, marketplaces: marketplaces, desired: { desired }, service: service)
    }

    @MainActor
    func testLaunchRepointsAStaleRegistrationWithoutReinstalling() async {
        let service = RepairRecordingService()
        let model = makeModel(
            listing: failedToLoadListing,
            marketplaces: marketplaceListing,
            desired: "/Users/t/Library/Application Support/localvoxtral/claude/marketplace",
            service: service
        )
        await model.repairMarketplaceRegistrationAtLaunch()

        // Exactly one command, and not one that touches the install: an
        // uninstall here would take the user's plugin with it.
        XCTAssertEqual(service.calls.withLock { $0 }, ["repair"])
    }

    @MainActor
    func testLaunchLeavesAHealthyRegistrationAlone() async {
        let service = RepairRecordingService()
        let healthy = """
        [{"id":"localvoxtral@localvoxtral","version":"1.1.0","scope":"user","enabled":true}]
        """
        let marketplaces = """
        [{"name":"localvoxtral","source":"directory","path":"/Users/t/Library/Application Support/localvoxtral/claude/marketplace"}]
        """
        let model = makeModel(
            listing: healthy,
            marketplaces: marketplaces,
            desired: "/Users/t/Library/Application Support/localvoxtral/claude/marketplace",
            service: service
        )
        await model.repairMarketplaceRegistrationAtLaunch()

        XCTAssertEqual(service.calls.withLock { $0 }, [])
    }

    @MainActor
    func testLaunchNeverInstallsAPluginTheUserDoesNotHave() async {
        let service = RepairRecordingService()
        let model = makeModel(
            listing: "[]",
            marketplaces: marketplaceListing,
            desired: "/Users/t/Library/Application Support/localvoxtral/claude/marketplace",
            service: service
        )
        await model.repairMarketplaceRegistrationAtLaunch()

        XCTAssertEqual(service.calls.withLock { $0 }, [])
        XCTAssertEqual(model.localPluginStatus, .notInstalled)
    }
}

extension ClaudeMarketplaceLaunchRepairTests {
    @MainActor
    func testTheMirrorPathIsReadWhenTheRepairRuns() async {
        // The model is built during startup, BEFORE the launch maintenance
        // that creates the mirror. A value captured at construction is nil for
        // the whole of the first launch after an update — the one launch that
        // has a rotting registration to take over.
        let service = RepairRecordingService()
        let mirror = Mutex<String?>(nil)
        let model = makeModel(
            listing: """
            [{"id":"localvoxtral@localvoxtral","version":"1.1.0","scope":"user","enabled":true}]
            """,
            marketplaces: marketplaceListing,
            desired: { mirror.withLock { $0 } },
            service: service
        )
        mirror.withLock { $0 = "/Users/t/Library/Application Support/localvoxtral/claude/marketplace" }

        await model.repairMarketplaceRegistrationAtLaunch()
        XCTAssertEqual(service.calls.withLock { $0 }, ["repair"])
    }
}

/// Records which plugin command the model chose.
private final class RepairRecordingService: ClaudePluginInstalling, Sendable {
    let calls = Mutex<[String]>([])

    func installPlugin() throws { calls.withLock { $0.append("install") } }
    func updatePlugin() throws { calls.withLock { $0.append("reinstall") } }
    func updateInstalledPlugin() throws { calls.withLock { $0.append("update") } }
    func uninstallPlugin() throws { calls.withLock { $0.append("uninstall") } }
    func repairMarketplaceRegistration() throws { calls.withLock { $0.append("repair") } }
}

// MARK: - Which path the service actually registers

final class ClaudeMarketplaceRegistrationArgvTests: XCTestCase {
    private let mirror = URL(fileURLWithPath: "/Users/t/Library/Application Support/localvoxtral/claude/marketplace")
    private let bundle = URL(fileURLWithPath: "/private/tmp/localvoxtral-try.X/extracted/localvoxtral.app/Contents/Resources/claude-code-marketplace")

    private func service(
        marketplace: URL?,
        repair: URL?,
        capture: ClaudeMarketplaceInvocationLog
    ) -> ClaudePluginInstallService {
        ClaudePluginInstallService(
            claudeExecutableURL: URL(fileURLWithPath: "/usr/local/bin/claude"),
            marketplaceURL: marketplace,
            repairMarketplaceURL: repair,
            publisherURL: nil,
            runner: { invocation in
                capture.record(invocation.arguments)
                return .init(exitCode: 0, message: "")
            }
        )
    }

    func testRepairRegistersTheMirrorEvenWhenTheServiceCouldFallBackToTheBundle() throws {
        let log = ClaudeMarketplaceInvocationLog()
        // `live()` hands `marketplaceURL` the bundle when no mirror exists, so
        // a repair that used it would re-pin the rot it is repairing.
        try service(marketplace: bundle, repair: mirror, capture: log).repairMarketplaceRegistration()

        XCTAssertEqual(log.arguments, [["plugin", "marketplace", "add", mirror.path]])
    }

    func testRepairRefusesWhenThereIsNoMirrorToRegister() {
        let log = ClaudeMarketplaceInvocationLog()
        XCTAssertThrowsError(
            try service(marketplace: bundle, repair: nil, capture: log).repairMarketplaceRegistration()
        ) { error in
            XCTAssertEqual(error as? ClaudePluginInstallService.ServiceError, .marketplaceUnavailable)
        }
        // Nothing ran: refusing is the point, not falling back.
        XCTAssertEqual(log.arguments, [])
    }

    func testAJSONCaptureIsNotTruncatedForDisplay() {
        // The listing is PARSED. A capture cut at the display cap decodes as
        // nothing, and every decision taken from it silently stops.
        let long = String(repeating: "x", count: 4_000)
        XCTAssertTrue(
            ClaudePluginInstallService.isMachineReadable(
                .init(arguments: ["plugin", "marketplace", "list", "--json"])
            )
        )
        XCTAssertFalse(
            ClaudePluginInstallService.isMachineReadable(
                .init(arguments: ["plugin", "marketplace", "add", long])
            )
        )
    }
}

/// Collects the argv of every CLI call a service made.
private final class ClaudeMarketplaceInvocationLog: @unchecked Sendable {
    private let storage = Mutex<[[String]]>([])

    func record(_ arguments: [String]) { storage.withLock { $0.append(arguments) } }
    var arguments: [[String]] { storage.withLock { $0 } }
}
