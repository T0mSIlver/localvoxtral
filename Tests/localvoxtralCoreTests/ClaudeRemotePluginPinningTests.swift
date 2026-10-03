import Foundation
@testable import localvoxtralCore
import localvoxtralTestSupport
import XCTest

/// The host installs the plugin this app ships, whatever GitHub's main holds
/// (#836). The setup scripts run for real under `/bin/sh` against a fake
/// `claude` that models the CLI behaviour measured on 2.1.283: `marketplace
/// add` replaces a name's source and keeps the installed plugin, `plugin
/// update` installs whatever the marketplace offers (older included), and a
/// GitHub marketplace offers main's head. It also logs every argv it gets,
/// which is what a host's process list shows every account (#1621), and
/// `plugin configure --values-stdin` stores the token it reads from stdin.
final class ClaudeRemotePluginPinningTests: XCTestCase {
    private static let mainHead = "1.99.0"

    private static let fakeClaude = """
        #!/bin/sh
        S="$HOME/fake-claude"
        mkdir -p "$S"
        printf '%s\\n' "$*" >>"$S/argv"
        offered() {
          src=$(cat "$S/source" 2>/dev/null || true)
          case "$src" in
            github) echo \(mainHead) ;;
            /*) sed -n 's/^ *"version": *"\\([0-9.]*\\)".*/\\1/p' "$src/plugins/localvoxtral-remote/.claude-plugin/plugin.json" | head -n 1 ;;
            *) exit 1 ;;
          esac
        }
        case "$1 $2 ${3-}" in
          "plugin list --json")
            printf '['
            [ ! -f "$S/installed" ] || printf '{"id":"localvoxtral-remote@localvoxtral","version":"%s","scope":"user"}' "$(cat "$S/installed")"
            printf ']\\n' ;;
          "plugin marketplace add")
            case "$4" in /*) echo "$4" >"$S/source" ;; *) echo github >"$S/source" ;; esac ;;
          "plugin marketplace update") [ -f "$S/source" ] ;;
          "plugin marketplace remove") rm -f "$S/source" "$S/installed" "$S/token" ;;
          "plugin uninstall "*) rm -f "$S/installed" "$S/token" ;;
          "plugin configure "*)
            [ -f "$S/installed" ] && [ "${4-}" = --values-stdin ] && [ ! -f "$S/no-configure" ] || exit 1
            sed -n 's/^{"token":"\\(.*\\)"}$/\\1/p' >"$S/token" ;;
          "plugin update "*) [ -f "$S/installed" ] && offered >"$S/installed.new" && mv "$S/installed.new" "$S/installed" ;;
          "plugin install "*)
            [ -f "$S/installed" ] || { offered >"$S/installed.new" && mv "$S/installed.new" "$S/installed"; }
            for a in "$@"; do case "$a" in token=*) echo "${a#token=}" >"$S/token" ;; esac; done ;;
          *) exit 2 ;;
        esac
        """

    private var home: URL!

    /// The fake CLI, written once for the class: executing a script the
    /// system has not seen before cost 170–260 ms on the build host against
    /// 23 ms for one it has (measured in `VibeRemoteShimTests`), and every
    /// test here used to write its own. The script reads all of its state
    /// from `$HOME`, so each test still gets a fresh host; only the
    /// executable is shared, linked into each test's own
    /// `$HOME/.local/bin` — the directory the setup script's PATH resolver
    /// searches — so the resolver's discovery path is exactly a real host's.
    private static let sharedCLIDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("lvx-pinning-cli-\(UUID().uuidString)")

    private static func writeFakeClaudeOnce() throws {
        let claude = sharedCLIDirectory.appendingPathComponent("claude")
        guard !FileManager.default.fileExists(atPath: claude.path) else { return }
        try FileManager.default.createDirectory(at: sharedCLIDirectory, withIntermediateDirectories: true)
        try fakeClaude.write(to: claude, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: claude.path)
    }

    override class func tearDown() {
        try? FileManager.default.removeItem(at: sharedCLIDirectory)
        super.tearDown()
    }

    override func setUpWithError() throws {
        try Self.writeFakeClaudeOnce()
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("lvx-pinning-\(UUID().uuidString)")
        let bin = home.appendingPathComponent(".local/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: bin.appendingPathComponent("claude"),
            withDestinationURL: Self.sharedCLIDirectory.appendingPathComponent("claude")
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    /// A host enrolled from the GitHub marketplace at `installed`, token set.
    private func enrollFromGitHub(installed: String) throws {
        let state = home.appendingPathComponent("fake-claude")
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        try "github\n".write(to: state.appendingPathComponent("source"), atomically: true, encoding: .utf8)
        try "\(installed)\n".write(to: state.appendingPathComponent("installed"), atomically: true, encoding: .utf8)
        try "host-token\n".write(to: state.appendingPathComponent("token"), atomically: true, encoding: .utf8)
    }

    private func state(_ name: String) -> String? {
        (try? String(contentsOf: home.appendingPathComponent("fake-claude/\(name)"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `ssh <alias> /bin/sh -s`, minus the ssh: the script runs here, in the
    /// fake host's HOME.
    private func localShellService() -> ClaudeRemoteEnrollmentService {
        let home = home.path
        return ClaudeRemoteEnrollmentService(runner: { invocation in
            let scratch = URL(fileURLWithPath: home).appendingPathComponent("run-\(UUID().uuidString)")
            try invocation.standardInput.write(to: scratch.appendingPathExtension("sh"))
            let exitCode = try SpawnAndWait.run(
                "/bin/sh",
                arguments: ["-s"],
                environment: ["HOME": home, "PATH": "/usr/bin:/bin"],
                standardInput: scratch.appendingPathExtension("sh").path,
                output: scratch.appendingPathExtension("out").path
            )
            let output = (try? String(contentsOf: scratch.appendingPathExtension("out"), encoding: .utf8)) ?? ""
            return .init(exitCode: exitCode, message: output)
        })
    }

    func testAHostOnAnOlderPluginGetsTheAppsVersionWhileMainIsAhead() throws {
        try enrollFromGitHub(installed: "1.4.0")
        XCTAssertEqual(
            try localShellService().setupRemotePlugin(sshHostAlias: "builder", token: nil, remoteForwardPort: 28_511),
            .updated
        )
        XCTAssertEqual(state("installed"), ClaudeRemoteEnrollmentService.remotePluginVersion)
        XCTAssertEqual(state("token"), "host-token", "an update keeps the stored token")
    }

    func testAHostAheadOfTheAppComesBackToTheAppsVersion() throws {
        try enrollFromGitHub(installed: Self.mainHead)
        XCTAssertEqual(
            try localShellService().setupRemotePlugin(sshHostAlias: "builder", token: nil, remoteForwardPort: 28_511),
            .updated
        )
        XCTAssertEqual(state("installed"), ClaudeRemoteEnrollmentService.remotePluginVersion)
        XCTAssertEqual(state("token"), "host-token", "going back keeps the stored token")
    }

    func testAFreshInstallUsesTheAppsCopyAndLeavesItOnTheHost() throws {
        XCTAssertEqual(
            try localShellService().setupRemotePlugin(sshHostAlias: "builder", token: "t0k", remoteForwardPort: 28_511),
            .installed
        )
        XCTAssertEqual(state("installed"), ClaudeRemoteEnrollmentService.remotePluginVersion)
        XCTAssertEqual(state("token"), "t0k")

        // The source is the copy, byte for byte, and nothing else is left
        // beside it.
        let directory = home.appendingPathComponent(".local/share/localvoxtral/claude-marketplace")
        XCTAssertEqual(state("source"), directory.path)
        let bundled = try XCTUnwrap(ClaudeRemoteMarketplaceFiles.bundled())
        XCTAssertEqual(
            try FileManager.default.subpathsOfDirectory(atPath: directory.path)
                .filter { path in
                    var isDirectory: ObjCBool = false
                    FileManager.default.fileExists(
                        atPath: directory.appendingPathComponent(path).path, isDirectory: &isDirectory
                    )
                    return !isDirectory.boolValue
                }
                .sorted(),
            bundled.files.map(\.relativePath).sorted()
        )
        for file in bundled.files {
            let url = directory.appendingPathComponent(file.relativePath)
            XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), file.content, file.relativePath)
            XCTAssertEqual(FileManager.default.isExecutableFile(atPath: url.path), file.executable, file.relativePath)
        }
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(
                atPath: directory.deletingLastPathComponent().path
            ),
            ["claude-marketplace"],
            "no staging tree survives the swap"
        )
    }

    /// #1621: the token reaches the CLI on stdin, and no argv carries it.
    func testTheTokenReachesTheHostsCLIOutsideEveryArgv() throws {
        let secret = "host-token-\(UUID().uuidString)"
        XCTAssertEqual(
            try localShellService().setupRemotePlugin(sshHostAlias: "builder", token: secret, remoteForwardPort: 28_511),
            .installed
        )
        XCTAssertEqual(state("token"), secret)
        let argv = try XCTUnwrap(state("argv"))
        XCTAssertTrue(argv.contains("plugin install"), argv)
        XCTAssertFalse(argv.contains(secret), "the token was on a command line")

        // A rotation on an installed plugin takes the same route.
        try FileManager.default.removeItem(at: home.appendingPathComponent("fake-claude/argv"))
        let rotated = "host-token-\(UUID().uuidString)"
        XCTAssertEqual(
            try localShellService().setupRemotePlugin(sshHostAlias: "builder", token: rotated, remoteForwardPort: 28_511),
            .alreadyCurrent
        )
        XCTAssertEqual(state("token"), rotated)
        XCTAssertFalse(try XCTUnwrap(state("argv")).contains(rotated))
    }

    /// A CLI that cannot take the token from stdin fails setup with its own
    /// exit code, and a fresh install it left tokenless is removed again, so
    /// a later run installs it with a token instead of reporting it current.
    func testACLIThatCannotStoreTheTokenLeavesNoTokenlessInstall() throws {
        let state = home.appendingPathComponent("fake-claude")
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: state.appendingPathComponent("no-configure").path, contents: nil)
        XCTAssertThrowsError(
            try localShellService().setupRemotePlugin(sshHostAlias: "builder", token: "t0k", remoteForwardPort: 28_511)
        ) { error in
            guard case ClaudeRemoteEnrollmentService.ServiceError.commandFailed(_, _, 48, _) = error else {
                return XCTFail("expected exit 48, got \(error)")
            }
        }
        XCTAssertNil(self.state("installed"))
        XCTAssertFalse(try XCTUnwrap(self.state("argv")).contains("t0k"))
    }

    func testABuildWhoseCopyCarriesAnotherVersionChangesNothing() throws {
        try enrollFromGitHub(installed: "1.4.0")
        var marketplace = try XCTUnwrap(ClaudeRemoteMarketplaceFiles.bundled())
        let manifest = try XCTUnwrap(marketplace.files.firstIndex {
            $0.relativePath == "plugins/localvoxtral-remote/.claude-plugin/plugin.json"
        })
        marketplace.files[manifest].content = marketplace.files[manifest].content.replacingOccurrences(
            of: "\"\(ClaudeRemoteEnrollmentService.remotePluginVersion)\"", with: "\"0.0.1\""
        )
        XCTAssertThrowsError(
            try localShellService().setupRemotePlugin(
                sshHostAlias: "builder", token: nil, remoteForwardPort: 28_511, marketplace: marketplace
            )
        ) { error in
            guard case ClaudeRemoteEnrollmentService.ServiceError.commandFailed(_, _, 47, _) = error else {
                return XCTFail("expected exit 47, got \(error)")
            }
        }
        XCTAssertEqual(state("installed"), "1.4.0")
        XCTAssertEqual(state("source"), "github")
    }
}
