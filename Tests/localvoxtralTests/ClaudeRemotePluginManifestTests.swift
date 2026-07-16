import ClaudeContextWire
import Foundation
import XCTest
@testable import localvoxtral

/// Validates the `localvoxtral-remote` plugin as an artifact.
///
/// This manifest is the entire remote-side install: there is no shim script and
/// no binary to catch a mistake at runtime, and the machine it runs on is one we
/// cannot see. A typo'd URL, a lost `Authorization` header, or a missing
/// `allowedEnvVars` entry would not fail loudly — it would fail open, forever,
/// and look exactly like "the tunnel isn't up". These assertions are the only
/// thing standing between that and a user.
final class ClaudeRemotePluginManifestTests: XCTestCase {
    private var marketplace: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        marketplace = try XCTUnwrap(ClaudePluginAssets.developmentMarketplaceURL())
    }

    private func json(at url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private var pluginRoot: URL {
        marketplace.appendingPathComponent("plugins/\(ClaudePluginAssets.remotePluginName)")
    }

    private func manifest() throws -> [String: Any] {
        try json(at: pluginRoot.appendingPathComponent(".claude-plugin/plugin.json"))
    }

    private func hooksByEvent() throws -> [String: [[String: Any]]] {
        let hooks = try json(at: pluginRoot.appendingPathComponent("hooks/hooks.json"))
        return try XCTUnwrap(hooks["hooks"] as? [String: [[String: Any]]])
    }

    /// Every hook entry across every event, paired with its event name.
    private func allHookEntries() throws -> [(event: String, entry: [String: Any])] {
        try hooksByEvent().flatMap { event, matchers in
            matchers.flatMap { matcher -> [(String, [String: Any])] in
                let entries = matcher["hooks"] as? [[String: Any]] ?? []
                return entries.map { (event, $0) }
            }
        }
    }

    // MARK: Plugin

    func testPluginManifestIsValidAndNamesItsHooks() throws {
        let manifest = try manifest()
        XCTAssertEqual(manifest["name"] as? String, ClaudePluginAssets.remotePluginName)
        XCTAssertNotNil(manifest["description"] as? String)
        XCTAssertNotNil(manifest["version"] as? String)
        XCTAssertEqual(manifest["hooks"] as? String, "./hooks/hooks.json")
    }

    func testPluginDeclaresNoTokenConsumingSurfaces() throws {
        // Same rule as the local plugin: a data channel, not a Claude feature.
        // A skill or command would spend the user's tokens on a remote host for
        // something they never asked Claude to do.
        let manifest = try manifest()
        for key in ["skills", "commands", "agents", "mcpServers", "statusLine"] {
            XCTAssertNil(manifest[key], "the remote plugin must not declare \(key)")
        }
        for directory in ["skills", "commands", "agents"] {
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: pluginRoot.appendingPathComponent(directory).path),
                "the remote plugin must not ship a \(directory)/ directory"
            )
        }
    }

    func testPluginShipsNoExecutableOfAnyKind() throws {
        // The whole premise: nothing to install on the remote but the manifest.
        // No Python, no jq, no nc, no Node, no publisher binary. If a file ever
        // appears here that a shell could run, the premise is gone.
        let contents = try FileManager.default.subpathsOfDirectory(atPath: pluginRoot.path)
        for path in contents {
            let full = pluginRoot.appendingPathComponent(path)
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: full.path, isDirectory: &isDirectory)
            guard !isDirectory.boolValue else { continue }
            XCTAssertFalse(
                FileManager.default.isExecutableFile(atPath: full.path),
                "the remote plugin must ship no executables, found \(path)"
            )
            XCTAssertTrue(
                path.hasSuffix(".json"),
                "the remote plugin must ship JSON manifests only, found \(path)"
            )
        }
    }

    // MARK: userConfig

    func testTokenUserConfigIsDeclaredSensitive() throws {
        let manifest = try manifest()
        let userConfig = try XCTUnwrap(manifest["userConfig"] as? [String: Any])
        let token = try XCTUnwrap(
            userConfig[ClaudeRemoteEnrollmentService.tokenConfigKey] as? [String: Any]
        )
        XCTAssertEqual(token["type"] as? String, "string")
        XCTAssertNotNil(token["description"] as? String)
        // Without this the credential is a plain config value Claude Code may
        // echo back in a plugin listing.
        XCTAssertEqual(token["sensitive"] as? Bool, true, "the token must be marked sensitive")
    }

    func testNoTokenValueIsBakedIntoTheManifest() throws {
        // The manifest is public, in a public repo. The only token in it is the
        // env var reference; an actual credential here would ship to everyone.
        let manifestText = try String(
            contentsOf: pluginRoot.appendingPathComponent(".claude-plugin/plugin.json"), encoding: .utf8
        )
        let hooksText = try String(
            contentsOf: pluginRoot.appendingPathComponent("hooks/hooks.json"), encoding: .utf8
        )
        for text in [manifestText, hooksText] {
            XCTAssertFalse(text.contains("Bearer lv"), "no literal credential may appear")
        }
        let userConfig = try XCTUnwrap(try manifest()["userConfig"] as? [String: Any])
        let token = try XCTUnwrap(
            userConfig[ClaudeRemoteEnrollmentService.tokenConfigKey] as? [String: Any]
        )
        XCTAssertEqual(token["default"] as? String, "", "the token must default to empty, never to a value")
    }

    // MARK: Hooks

    func testDeclaresEveryRequiredEvent() throws {
        XCTAssertEqual(
            Set(try hooksByEvent().keys),
            ["UserPromptSubmit", "CwdChanged", "PostToolUse", "Stop", "SessionEnd"]
        )
    }

    func testEveryHookIsHTTPWithNoCommandAnywhere() throws {
        // A `command` hook on the remote would need a shell, a binary, and a
        // publisher we deliberately do not ship there.
        for (event, entry) in try allHookEntries() {
            XCTAssertEqual(entry["type"] as? String, "http", "\(event) must be an http hook")
            XCTAssertNil(entry["command"], "\(event) must not declare a command")
        }
    }

    func testEveryHookPostsToTheLoopbackListenerOnItsOwnEventPath() throws {
        for (event, entry) in try allHookEntries() {
            let url = try XCTUnwrap(entry["url"] as? String)
            // Loopback, literally. The tunnel's remote end is 127.0.0.1 on the
            // remote host; any other address would send the user's prompts
            // across their network in the clear.
            XCTAssertTrue(
                url.hasPrefix("http://127.0.0.1:\(ClaudeRemoteListenerLimits.default.port)"),
                "\(event) must post to the tunnelled loopback port, got \(url)"
            )
            XCTAssertTrue(
                url.hasSuffix("\(ClaudeRemoteHTTPCodec.hookPathPrefix)\(event)"),
                "\(event) must post to its own event path, got \(url)"
            )
            // The path is what gives the parser a fallback event name.
            XCTAssertEqual(
                ClaudeRemoteHTTPCodec.eventName(
                    inPath: String(url.dropFirst("http://127.0.0.1:8473".count))
                ),
                event
            )
        }
    }

    func testHookPortDoesNotCollideWithTheManagedBackends() throws {
        // 8471 is voxmlx and 8472 is polishd. Reusing either would make a hook
        // POST land in an inference server — or worse, make the listener refuse
        // to bind and take the backend's port when it started first.
        for (_, entry) in try allHookEntries() {
            let url = try XCTUnwrap(entry["url"] as? String)
            XCTAssertFalse(url.contains(":8471"))
            XCTAssertFalse(url.contains(":8472"))
        }
    }

    func testEveryHookSendsTheTokenAndAllowsItsEnvVar() throws {
        for (event, entry) in try allHookEntries() {
            let headers = try XCTUnwrap(entry["headers"] as? [String: String], "\(event) needs headers")
            let authorization = try XCTUnwrap(headers["Authorization"], "\(event) must authenticate")
            XCTAssertEqual(authorization, "Bearer ${CLAUDE_PLUGIN_OPTION_TOKEN}")

            // Without allowedEnvVars the interpolation does not happen and the
            // header ships the literal `${...}` — which the listener rejects as
            // a malformed token. Fail-open all the way down, and invisible.
            let allowed = try XCTUnwrap(entry["allowedEnvVars"] as? [String], "\(event) needs allowedEnvVars")
            XCTAssertEqual(allowed, ["CLAUDE_PLUGIN_OPTION_TOKEN"])
        }
    }

    func testTheEnvVarMatchesTheDeclaredUserConfigKey() throws {
        // Claude Code exposes userConfig to hooks as CLAUDE_PLUGIN_OPTION_<KEY>.
        // The declared key and the variable the header reads must agree, or the
        // config silently does nothing.
        let expected = "CLAUDE_PLUGIN_OPTION_"
            + ClaudeRemoteEnrollmentService.tokenConfigKey.uppercased()
        for (event, entry) in try allHookEntries() {
            let headers = try XCTUnwrap(entry["headers"] as? [String: String])
            XCTAssertTrue(
                headers["Authorization"]?.contains(expected) == true,
                "\(event) must read \(expected)"
            )
            XCTAssertEqual(entry["allowedEnvVars"] as? [String], [expected])
        }
    }

    func testEveryHookHasAShortTimeout() throws {
        for (event, entry) in try allHookEntries() {
            let timeout = try XCTUnwrap(entry["timeout"] as? Int, "\(event) needs a timeout")
            // A hook on a remote host reaches us through a tunnel that may not
            // exist. Without a short ceiling, every turn on a host whose forward
            // silently failed would stall for the default.
            XCTAssertLessThanOrEqual(timeout, 5)
            XCTAssertGreaterThan(timeout, 0)
        }
    }

    /// Claude Code supports `async` only for command hooks. The remote plugin is
    /// declarative HTTP, so every handler remains synchronous with a one-second
    /// fail-open ceiling.
    func testHTTPHooksDoNotDeclareCommandOnlyAsync() throws {
        for (event, entry) in try allHookEntries() {
            XCTAssertNil(entry["async"], "\(event): async is command-hook-only")
            XCTAssertEqual(entry["timeout"] as? Int, 1)
        }
    }

    func testPostToolUseMatchesOnlyFileBearingTools() throws {
        let matchers = try XCTUnwrap(try hooksByEvent()["PostToolUse"])
        let matcher = try XCTUnwrap(matchers.first?["matcher"] as? String)
        for tool in ["Read", "Edit", "Write", "NotebookEdit"] {
            XCTAssertTrue(matcher.contains(tool), "matcher should cover \(tool)")
        }
        // Bash carries a command string, not a file path.
        XCTAssertFalse(matcher.contains("Bash"))
    }

    func testEventsThatCarryNoToolUseDeclareNoMatcher() throws {
        for event in ["UserPromptSubmit", "Stop", "SessionEnd"] {
            let matchers = try XCTUnwrap(try hooksByEvent()[event])
            XCTAssertNil(matchers.first?["matcher"], "\(event) needs no tool matcher")
        }
    }

    func testDeclaresNoWatchPathsAndNoFileChangedHook() throws {
        let hooks = try hooksByEvent()
        XCTAssertNil(hooks["FileChanged"])
        for (_, matchers) in hooks {
            for matcher in matchers {
                XCTAssertNil(matcher["watchPaths"])
            }
        }
    }

    /// Every hook name in the manifest must be one the wire can actually decode.
    func testEveryDeclaredEventIsAKnownWireEvent() throws {
        for event in try hooksByEvent().keys {
            XCTAssertNotNil(
                ClaudeHookEvent(rawValue: event),
                "\(event) is not a wire event; the listener would reject every one of its records"
            )
        }
    }

    // MARK: Documentation
    //
    // The README is the only instruction set a user gets for a machine we cannot
    // see. Every caveat below has a failure mode that looks like "it just does
    // not work" — silent, with nothing in any log to go on — so each one is
    // pinned here rather than trusted to survive the next edit.

    private func readme() throws -> String {
        try String(contentsOf: marketplace.appendingPathComponent("README.md"), encoding: .utf8)
    }

    func testReadmeDocumentsTheTunnelAndTheInstallSide() throws {
        let readme = try readme()
        XCTAssertTrue(readme.contains("RemoteForward 8473 127.0.0.1:8473"))
        XCTAssertTrue(
            readme.contains("claude plugin marketplace add ")
                && readme.contains(ClaudeRemoteEnrollmentService.repositoryMarketplaceReference),
            "a remote host installs from the repo, not from an app bundle it does not have"
        )
        XCTAssertTrue(readme.contains("claude plugin install localvoxtral-remote@localvoxtral"))
        // Installing the wrong plugin on the wrong side fails open forever and
        // looks exactly like a tunnel problem.
        XCTAssertTrue(readme.contains("Install it on the REMOTE host, not on your Mac"))
    }

    func testReadmeDocumentsTheExitOnForwardFailureTradeoff() throws {
        let readme = try readme()
        XCTAssertTrue(readme.contains("ExitOnForwardFailure no"))
        XCTAssertTrue(
            readme.lowercased().contains("silent"),
            "the cost of `no` is a silently absent tunnel; a user who is not told will not look"
        )
    }

    func testReadmeDocumentsTheTmuxTitlePassthroughCaveat() throws {
        let readme = try readme()
        XCTAssertTrue(readme.contains("tmux"))
        XCTAssertTrue(readme.contains("set-titles on"), "the fix, not just the symptom")
        XCTAssertTrue(
            readme.lowercased().contains("unjoined"),
            "and what you lose without it: the screen join, not the off-screen context"
        )
    }

    func testReadmeDocumentsUninstallAndRevocation() throws {
        let readme = try readme()
        XCTAssertTrue(readme.contains("claude plugin uninstall localvoxtral-remote@localvoxtral"))
        XCTAssertTrue(readme.contains("claude plugin marketplace remove localvoxtral"))
        XCTAssertTrue(
            readme.contains("revoke the host in localvoxtral"),
            "revocation is the real off switch and must not read as an optional last step"
        )
        XCTAssertTrue(readme.lowercased().contains("rotat"))
    }

    func testReadmeDocumentsThatPlainSSHIsUnchangedAndNothingIsOnByDefault() throws {
        let readme = try readme()
        XCTAssertTrue(readme.contains("Plain SSH still works exactly as before"))
        XCTAssertTrue(
            readme.contains("binds no port at all"),
            "a user must be able to confirm that not enrolling costs them nothing"
        )
    }

    func testReadmeStatesTheTokensLimits() throws {
        let readme = try readme()
        XCTAssertTrue(readme.contains("cannot make the app read a local file"))
        XCTAssertTrue(readme.contains("HISTCONTROL=ignorespace"), "the token-in-history caveat")
    }
}
