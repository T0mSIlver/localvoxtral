import ClaudeContextWire
import Foundation
import Synchronization
import XCTest
@testable import localvoxtralCore

private final class RecordingCodexCLI: Sendable {
    private let calls = Mutex<[[String]]>([])
    private let answer: @Sendable ([String]) -> ClaudePluginInstallService.RunResult

    init(_ answer: @escaping @Sendable ([String]) -> ClaudePluginInstallService.RunResult = { _ in
        .init(exitCode: 0, message: "")
    }) {
        self.answer = answer
    }

    var invocations: [[String]] { calls.withLock { $0 } }

    var runner: CodexPluginInstallService.Runner {
        { [self] invocation in
            calls.withLock { $0.append(invocation.arguments) }
            return answer(invocation.arguments)
        }
    }
}

final class CodexPluginInstallServiceTests: XCTestCase {
    private let mirror = URL(fileURLWithPath: "/Users/t/Library/Application Support/localvoxtral/codex/marketplace")

    private func service(_ cli: RecordingCodexCLI, codex: Bool = true) -> CodexPluginInstallService {
        CodexPluginInstallService(
            codexExecutableURL: codex ? URL(fileURLWithPath: "/opt/homebrew/bin/codex") : nil,
            marketplaceURL: mirror,
            runner: cli.runner
        )
    }

    func testInstallRegistersTheMirrorThenAddsThePlugin() throws {
        let cli = RecordingCodexCLI()
        try service(cli).install()
        XCTAssertEqual(cli.invocations, [
            ["plugin", "marketplace", "add", mirror.path],
            ["plugin", "add", "localvoxtral@localvoxtral"],
        ])
    }

    /// Codex 0.156.0 refuses, with exit 1, to add a name already registered
    /// from another path: an install from a dev build or an older bundle.
    func testAMarketplaceRegisteredElsewhereIsReplaced() throws {
        let cli = RecordingCodexCLI { arguments in
            arguments.starts(with: ["plugin", "marketplace", "add"]) && arguments.count == 4
                ? .init(exitCode: 1, message: "Error: marketplace 'localvoxtral' is already added from a different source; remove it before adding this source")
                : .init(exitCode: 0, message: "")
        }
        XCTAssertThrowsError(try service(cli).install())
        XCTAssertEqual(Array(cli.invocations.prefix(3)), [
            ["plugin", "marketplace", "add", mirror.path],
            ["plugin", "marketplace", "remove", "localvoxtral"],
            ["plugin", "marketplace", "add", mirror.path],
        ], "the second add fails here too, so the install stops before `plugin add`")
    }

    func testAnyOtherMarketplaceFailureRemovesNothing() {
        let cli = RecordingCodexCLI { arguments in
            arguments.starts(with: ["plugin", "marketplace", "add"])
                ? .init(exitCode: 1, message: "Error: invalid marketplace file")
                : .init(exitCode: 0, message: "")
        }
        XCTAssertThrowsError(try service(cli).install())
        XCTAssertEqual(cli.invocations, [["plugin", "marketplace", "add", mirror.path]])
    }

    func testRemoveTakesThePluginThenTheMarketplace() throws {
        let cli = RecordingCodexCLI()
        try service(cli).remove()
        XCTAssertEqual(cli.invocations, [
            ["plugin", "remove", "localvoxtral@localvoxtral"],
            ["plugin", "marketplace", "remove", "localvoxtral"],
        ])
    }

    func testWithoutTheCLINothingRuns() {
        let cli = RecordingCodexCLI()
        XCTAssertThrowsError(try service(cli, codex: false).install()) {
            XCTAssertEqual($0 as? CodexPluginInstallService.ServiceError, .codexCLINotFound)
        }
        XCTAssertEqual(service(cli, codex: false).status(bundledVersion: "1.0.0"), .unknown)
        XCTAssertEqual(cli.invocations, [])
    }

    // MARK: Status, from `codex plugin list --json` as 0.156.0 prints it

    private func listing(version: String = "1.0.0", enabled: Bool = true) -> String {
        """
        {
          "installed": [
            {
              "pluginId": "localvoxtral@localvoxtral",
              "name": "localvoxtral",
              "marketplaceName": "localvoxtral",
              "version": "\(version)",
              "installed": true,
              "enabled": \(enabled),
              "source": {"source": "local", "path": "/x/integrations/codex/plugins/localvoxtral"},
              "marketplaceSource": {"sourceType": "local", "source": "/x/integrations/codex"},
              "installPolicy": "AVAILABLE",
              "authPolicy": "ON_INSTALL"
            }
          ],
          "available": []
        }
        """
    }

    func testTheListingDecidesTheStatus() {
        typealias S = CodexPluginInstallService
        XCTAssertEqual(S.status(listOutput: listing(), bundledVersion: "1.0.0"), .installed)
        XCTAssertEqual(S.status(listOutput: listing(version: "0.9.0"), bundledVersion: "1.0.0"), .updateAvailable)
        XCTAssertEqual(S.status(listOutput: listing(enabled: false), bundledVersion: "1.0.0"), .disabled)
        XCTAssertEqual(S.status(listOutput: #"{"installed": [], "available": []}"#, bundledVersion: "1.0.0"), .notInstalled)
        XCTAssertEqual(S.status(listOutput: "not json", bundledVersion: "1.0.0"), .unknown)
    }

    func testTheStatusCallAsksOnlyForOurMarketplace() {
        let text = listing()
        let cli = RecordingCodexCLI { _ in .init(exitCode: 0, message: text) }
        XCTAssertEqual(service(cli).status(bundledVersion: "1.0.0"), .installed)
        XCTAssertEqual(cli.invocations, [["plugin", "list", "--json", "--marketplace", "localvoxtral"]])
    }

    // MARK: The row

    func testTheRowIsJoiningOnlyOnceAHookWasHeard() {
        XCTAssertFalse(CodexPluginInstallService.Status.installed.joins(hookHeard: false))
        XCTAssertTrue(CodexPluginInstallService.Status.installed.joins(hookHeard: true))
        XCTAssertTrue(CodexPluginInstallService.Status.updateAvailable.joins(hookHeard: true))
        XCTAssertFalse(CodexPluginInstallService.Status.disabled.joins(hookHeard: true))
        XCTAssertEqual(
            CodexPluginInstallService.Status.installed.sentence(hookHeard: false),
            "Installed; trust its hooks when Codex next starts."
        )
        XCTAssertEqual(CodexPluginInstallService.Status.installed.sentence(hookHeard: true), "Installed.")
        XCTAssertNil(CodexPluginInstallService.Status.installed.primaryActionTitle)
    }

    func testAHeardHookIsRememberedAcrossLaunchesAndForgottenByAnInstall() {
        let stored = Mutex(false)
        let registry = ClaudeSessionRegistry(isProcessAlive: { _ in true })
        let memory = CodexHookHeardMemory(
            registry: registry,
            load: { stored.withLock { $0 } },
            save: { value in stored.withLock { $0 = value } }
        )
        XCTAssertFalse(memory.hasHeard())

        let record = ClaudeHookRecord(
            event: .sessionStart, agent: .codex, sessionID: "01a0dec1-c2ba-71b3-b640-a2568cef221b",
            timestamp: 0, process: ClaudeHookProcessInfo(hookPID: 2, claudePID: 3)
        )
        XCTAssertNotNil(registry.ingest(record, origin: .localAuthenticated(peerUID: 501)))
        XCTAssertTrue(memory.hasHeard())

        let nextLaunch = CodexHookHeardMemory(
            registry: ClaudeSessionRegistry(isProcessAlive: { _ in true }),
            load: { stored.withLock { $0 } },
            save: { value in stored.withLock { $0 = value } }
        )
        XCTAssertTrue(nextLaunch.hasHeard())

        memory.reset()
        XCTAssertFalse(memory.hasHeard())
        XCTAssertFalse(nextLaunch.hasHeard())
    }

    // MARK: The shipped plugin

    func testTheShippedMarketplaceMatchesTheNamesTheServiceUses() throws {
        let root = try XCTUnwrap(CodexPluginAssets.marketplaceURL(resourcesURL: nil))
        let manifest = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent(".agents/plugins/marketplace.json")))
                as? [String: Any]
        )
        XCTAssertEqual(manifest["name"] as? String, CodexPluginInstallService.marketplaceName)
        let plugins = try XCTUnwrap(manifest["plugins"] as? [[String: Any]])
        XCTAssertEqual(plugins.compactMap { $0["name"] as? String }, [CodexPluginInstallService.pluginName])
        XCTAssertNotNil(CodexPluginAssets.bundledPluginVersion(marketplaceURL: root))
    }

    /// The hash Codex trusts covers each handler as declared. Every hook runs
    /// the same fixed command; a change to it asks every user to trust the
    /// hooks again, so it is pinned here.
    func testTheHookCommandIsTheOneUsersTrusted() throws {
        let root = try XCTUnwrap(CodexPluginAssets.marketplaceURL(resourcesURL: nil))
        let data = try Data(contentsOf: root.appendingPathComponent("plugins/localvoxtral/hooks/hooks.json"))
        let hooks = try XCTUnwrap(
            (JSONSerialization.jsonObject(with: data) as? [String: Any])?["hooks"] as? [String: [[String: Any]]]
        )
        for (event, groups) in hooks {
            for handler in groups.flatMap({ $0["hooks"] as? [[String: Any]] ?? [] }) {
                XCTAssertEqual(handler["command"] as? String, #"sh "$PLUGIN_ROOT/hooks/publish.sh" 2>/dev/null || :"#, event)
                // SessionEnd is capped at 3 s; a larger value warns on every start.
                XCTAssertEqual(handler["timeout"] as? Int, event == "SessionEnd" ? 3 : 10, event)
            }
        }
    }
}
