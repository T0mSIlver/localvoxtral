import ClaudeContextWire
import Foundation
import Synchronization
import XCTest
@testable import localvoxtral

/// The Codex pane: its dot turns green only after a Codex hook reached the
/// app, because Codex skips an untrusted hook silently (#716).
final class CodexIntegrationsSettingsTests: XCTestCase {
    func testTheDotIsGreenOnlyOnceAHookWasHeard() {
        XCTAssertEqual(IntegrationsSidebarStatus.codexDot(status: .installed, hookHeard: false), .yellow)
        XCTAssertEqual(IntegrationsSidebarStatus.codexDot(status: .installed, hookHeard: true), .green)
        XCTAssertEqual(IntegrationsSidebarStatus.codexDot(status: .updateAvailable, hookHeard: true), .green)
        XCTAssertEqual(IntegrationsSidebarStatus.codexDot(status: .disabled, hookHeard: true), .yellow)
        XCTAssertEqual(IntegrationsSidebarStatus.codexDot(status: .notInstalled, hookHeard: true), .yellow)
        XCTAssertEqual(IntegrationsSidebarStatus.codexDot(status: .unknown, hookHeard: true), .grey)
    }

    /// An install forgets a hook heard before it: the new plugin's hooks may
    /// be waiting for the user's trust, and the row must say so.
    @MainActor
    func testAnInstallAsksForTrustUntilTheNextHookArrives() async {
        let calls = Mutex<[[String]]>([])
        let installed = Mutex(false)
        let listing = """
        {"installed": [{"pluginId": "localvoxtral@localvoxtral", "version": "1.0.0", \
        "installed": true, "enabled": true}], "available": []}
        """
        let service = CodexPluginInstallService(
            codexExecutableURL: URL(fileURLWithPath: "/opt/homebrew/bin/codex"),
            marketplaceURL: URL(fileURLWithPath: "/mirror"),
            runner: { invocation in
                calls.withLock { $0.append(invocation.arguments) }
                if invocation.arguments.starts(with: ["plugin", "add"]) { installed.withLock { $0 = true } }
                let text = installed.withLock { $0 } ? listing : #"{"installed": [], "available": []}"#
                return .init(exitCode: 0, message: invocation.arguments.contains("list") ? text : "")
            }
        )
        let registry = ClaudeSessionRegistry(isProcessAlive: { _ in true })
        let stored = Mutex(true)
        let model = ClaudeIntegrationSettingsModel(
            registry: nil,
            listener: nil,
            pluginService: { StubClaudePluginService() },
            performAsync: { body in
                do {
                    try body()
                    return nil
                } catch {
                    return ClaudePluginActionFailure(error)
                }
            },
            codexService: { service },
            codexBundledVersion: "1.0.0",
            codexHookMemory: CodexHookHeardMemory(
                registry: registry,
                load: { stored.withLock { $0 } },
                save: { value in stored.withLock { $0 = value } }
            )
        )

        await model.refreshCodexStatus()
        XCTAssertEqual(model.codexStatus, .notInstalled)
        XCTAssertEqual(model.codexStatus.primaryActionTitle, "Install")

        await model.installCodexPlugin()
        XCTAssertEqual(model.codexStatus, .installed)
        XCTAssertFalse(model.codexHookHeard, "a hook heard before the install proves nothing about it")
        XCTAssertEqual(model.codexResult ?? model.codexSentence, "Installed; trust its hooks when Codex next starts.")
        XCTAssertEqual(IntegrationsSidebarStatus.codexDot(status: model.codexStatus, hookHeard: model.codexHookHeard), .yellow)

        let record = ClaudeHookRecord(
            event: .sessionStart, agent: .codex, sessionID: "01a0dec1-c2ba-71b3-b640-a2568cef221b",
            timestamp: 0, process: ClaudeHookProcessInfo(hookPID: 2, claudePID: 3)
        )
        XCTAssertNotNil(registry.ingest(record, origin: .localAuthenticated(peerUID: 501)))
        await model.refreshCodexStatus()
        XCTAssertEqual(model.codexSentence, "Installed.")
        XCTAssertEqual(IntegrationsSidebarStatus.codexDot(status: model.codexStatus, hookHeard: model.codexHookHeard), .green)
        XCTAssertTrue(calls.withLock { $0 }.contains(["plugin", "add", "localvoxtral@localvoxtral"]))
    }
}
