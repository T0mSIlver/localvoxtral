import ClaudeContextWire
import Foundation
import Synchronization
import XCTest
@testable import localvoxtral

/// Counts reads of the Claude Desktop address, so "never asked" assertions are
/// about the read, not its result.
private final class OutcomeDesktopReadCounter: Sendable {
    private let value = Mutex(0)
    var count: Int { value.withLock { $0 } }
    func increment() { value.withLock { $0 += 1 } }
}

/// The one join line a dictation start writes to the unified log (#658), and
/// the overlay badge the same start derives, driven through
/// `SessionContextResolver.captureAtStart`.
///
/// The line is the only record of a join that survives the dictation: every
/// arm logs its outcome at `.info`, which the unified log does not keep, and
/// the gates used to note their cause only in a dogfood build.
@MainActor
final class ClaudeJoinOutcomeLineTests: XCTestCase {
    private let remoteEndpoint = "https://api.example.com/v1/chat/completions"
    private let desktopID = "local_fb53459c-6a7b-43b1-a326-52258b970501"
    private let desktop = TerminalScreenTarget(pid: 6060, bundleID: ClaudeDesktopAllowlist.bundleID)
    private let chrome = TerminalScreenTarget(pid: 5150, bundleID: BrowserTabAllowlist.chromeBundleID)

    private var lines: [String] = []

    /// A context with polishing on (loopback), both context settings on,
    /// Accessibility trusted and Claude Desktop frontmost — every gate open —
    /// whose join lines land in `lines`.
    private func makeContext(registry: ClaudeSessionRegistry, desktopReads: OutcomeDesktopReadCounter? = nil)
        -> SessionContextResolver
    {
        let suiteName = "localvoxtral.ClaudeJoinOutcomeLineTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        let settings = SettingsStore(defaults: defaults, environment: [:], secretStore: InMemorySecretStore())
        settings.llmPolishingEnabled = true
        settings.terminalScreenContextEnabled = true
        settings.claudeRepoContextEnabled = true
        let context = SessionContextResolver(settings: settings, textInsertion: TextInsertionService())
        context.textInsertion.debugSetAccessibilityTrusted(true)
        addTeardownBlock { context.textInsertion.debugSetAccessibilityTrusted(nil) }
        let address = "https://claude.ai/epitaxy/\(desktopID)"
        context.claudeSessionJoinResolver = ClaudeSessionJoinResolver(
            registry: registry,
            focusedDesktopSessionURL: { _ in
                desktopReads?.increment()
                return address
            }
        )
        context.joinOutcomeLog = { [weak self] in self?.lines.append($0) }
        TerminalScreenContextSource.debugFrontmostTargetOverride = { self.desktop }
        return context
    }

    private func emptyRegistry() -> ClaudeSessionRegistry {
        ClaudeSessionRegistry(now: { Date(timeIntervalSince1970: 1_000) }, isProcessAlive: { _ in true })
    }

    /// A registry holding one live local session that reports `desktopID`.
    private func registryWithDesktopSession() -> ClaudeSessionRegistry {
        let registry = emptyRegistry()
        registry.ingest(
            ClaudeHookRecord(
                event: .sessionStart,
                sessionID: "s1",
                timestamp: 0,
                rawCwd: "/Users/dev/secret-repo",
                process: ClaudeHookProcessInfo(hookPID: 777, claudePID: 9001, desktopSessionID: desktopID)
            ),
            origin: .localAuthenticated(peerUID: 501)
        )
        return registry
    }

    override func tearDown() async throws {
        TerminalScreenContextSource.debugFrontmostTargetOverride = nil
        lines = []
        try await super.tearDown()
    }

    // MARK: - Gates

    // Each gate writes exactly one line, naming itself. In a shipping build
    // these causes used to exist only as `#if LOCALVOXTRAL_DOGFOOD` notes.
    func testEveryGateWritesOneLineNamingIt() async {
        let cases: [(ClaudeJoinGate, @MainActor (SessionContextResolver) -> Void)] = [
            (.noPolishingEndpoint, { $0.settings.llmPolishingEnabled = false }),
            (.noResolver, { $0.claudeSessionJoinResolver = nil }),
            (.contextSettingsOff, {
                $0.settings.terminalScreenContextEnabled = false
                $0.settings.claudeRepoContextEnabled = false
            }),
            (.endpointNotPermitted, {
                $0.settings.polishingBackendMode = .externalURL
                $0.settings.llmPolishingEndpointURL = self.remoteEndpoint
            }),
            (.accessibilityNotTrusted, { $0.textInsertion.debugSetAccessibilityTrusted(false) }),
            (.noFrontmostTarget, { _ in TerminalScreenContextSource.debugFrontmostTargetOverride = { nil } }),
            (.browserWithoutSessionContext, {
                $0.settings.claudeRepoContextEnabled = false
                TerminalScreenContextSource.debugFrontmostTargetOverride = { self.chrome }
            }),
            (.desktopWithoutSessionContext, { $0.settings.claudeRepoContextEnabled = false }),
        ]
        for (gate, close) in cases {
            lines = []
            let context = makeContext(registry: registryWithDesktopSession())
            close(context)

            _ = await context.captureAtStart()

            XCTAssertEqual(lines, ["arm=none origin=none causes=\(gate.rawValue)"], gate.rawValue)
        }
    }

    // MARK: - Resolver outcomes

    // The joined arm and origin class, and nothing that names the session: no
    // desktop id, no session id, no workspace.
    func testADesktopJoinWritesItsArmAndNoIdentifiers() async throws {
        let context = makeContext(registry: registryWithDesktopSession())

        _ = await context.captureAtStart()

        XCTAssertEqual(context.claudeSessionJoin?.mechanism, .desktopSession)
        XCTAssertEqual(lines, ["arm=desktopSession origin=local causes=none"])
        let line = try XCTUnwrap(lines.first)
        for identifying in [desktopID, "s1", "secret-repo"] {
            XCTAssertFalse(line.contains(identifying), identifying)
        }
    }

    // The field case: focus is in a Desktop session whose hooks never reached
    // this Mac. The line names the arm's own cause, never the id it read.
    func testAnUnknownDesktopSessionWritesTheArmsCause() async {
        let context = makeContext(registry: emptyRegistry())

        _ = await context.captureAtStart()

        XCTAssertEqual(
            lines,
            ["arm=none origin=none causes=desktopSession: no live session reports this desktop session"]
        )
    }

    // MARK: - The badge the same start derives

    // An empty registry is what a dead hook tunnel looks like, and the badge
    // used to stay hidden for it. Focus inside a session view says the user
    // is dictating to a Claude Code session that did not join.
    func testAnUnknownDesktopSessionShowsUnjoinedWithAnEmptyRegistry() async {
        let context = makeContext(registry: emptyRegistry())

        let badge = await context.captureAtStart()

        XCTAssertEqual(badge, .unjoined)
    }

    // With only the screen setting on, neither a browser nor Claude Desktop is
    // asked anything, so there is no join to report on: no "No Claude session"
    // pill, however many sessions are live.
    func testOnlyTheScreenSettingShowsNoBadgeForDesktopOrABrowser() async {
        for target in [desktop, chrome] {
            let reads = OutcomeDesktopReadCounter()
            let context = makeContext(registry: registryWithDesktopSession(), desktopReads: reads)
            context.settings.claudeRepoContextEnabled = false
            TerminalScreenContextSource.debugFrontmostTargetOverride = { target }

            let badge = await context.captureAtStart()

            XCTAssertEqual(badge, .hidden, target.bundleID)
            XCTAssertEqual(reads.count, 0, target.bundleID)
        }
    }
}
