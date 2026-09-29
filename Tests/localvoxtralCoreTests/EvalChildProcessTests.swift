import Foundation
import XCTest
import localvoxtralTestSupport

/// The eval runs `say` through this wrapper, and through
/// `scripts/ci/say-proxy.sh` when `LV_EVAL_SAY_PROXY_DIR` is set (#960).
final class EvalChildProcessTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lv-child-process-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    func testProxyRequestEndsEveryArgumentWithANul() {
        XCTAssertEqual(
            EvalChildProcess.proxyRequest(arguments: ["-v", "Amélie", "l'heure $(x)\nsuite"]),
            Data("-v\u{0}Amélie\u{0}l'heure $(x)\nsuite\u{0}".utf8)
        )
        XCTAssertEqual(EvalChildProcess.proxyRequest(arguments: []), Data())
    }

    /// The real proxy script, serving a fake `say`: the listing lands in the
    /// caller's file, synthesis arguments arrive verbatim with say's exit
    /// code, and a refused request answers 64.
    func testRunThroughTheSayProxy() throws {
        let directory = try temporaryDirectory()
        let fakeSay = directory.appendingPathComponent("say")
        try """
            #!/bin/sh
            if [ "$#" -eq 2 ] && [ "$1" = -v ] && [ "$2" = '?' ]; then
              printf '%-30s%s\\n' 'Samantha (English (US))' 'en_US    # Hello' 'Thomas' 'fr_FR    # Bonjour'
              exit 0
            fi
            printf '%s\\n' "$@"
            exit 3
            """.write(to: fakeSay, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeSay.path)

        let proxyDirectory = directory.appendingPathComponent("proxy", isDirectory: true)
        let outputRoot = directory.appendingPathComponent("out", isDirectory: true)
        for sub in ["requests", "results"] {
            try FileManager.default.createDirectory(
                at: proxyDirectory.appendingPathComponent(sub), withIntermediateDirectories: true
            )
        }
        try FileManager.default.createDirectory(at: outputRoot, withIntermediateDirectories: true)

        let script = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts/ci/say-proxy.sh")
        let proxy = Process()
        proxy.executableURL = URL(fileURLWithPath: "/bin/bash")
        proxy.arguments = [script.path, proxyDirectory.path, outputRoot.path]
        proxy.environment = ProcessInfo.processInfo.environment.merging(["SAY_PROXY_SAY": fakeSay.path]) {
            $1
        }
        proxy.standardOutput = FileHandle.nullDevice
        proxy.standardError = FileHandle.nullDevice
        try proxy.run()
        defer {
            proxy.terminate()
            proxy.waitUntilExit()
        }

        let listing = directory.appendingPathComponent("voices.txt")
        XCTAssertEqual(
            try EvalChildProcess.run(
                "/usr/bin/say", arguments: ["-v", "?"], standardOutput: listing.path,
                discardStandardError: true, proxy: proxyDirectory, timeout: .seconds(30)
            ),
            0
        )
        XCTAssertTrue(try String(contentsOf: listing, encoding: .utf8).contains("Thomas"))

        let echoed = directory.appendingPathComponent("echoed.txt")
        let arguments = [
            "-o", outputRoot.appendingPathComponent("a.wav").path, "--file-format=WAVE",
            "--data-format=LEI16@16000", "-v", "Samantha (English (US))", "l'heure  $(date)",
        ]
        XCTAssertEqual(
            try EvalChildProcess.run(
                "/usr/bin/say", arguments: arguments, standardOutput: echoed.path,
                proxy: proxyDirectory, timeout: .seconds(30)
            ),
            3
        )
        XCTAssertEqual(
            try String(contentsOf: echoed, encoding: .utf8),
            arguments.map { $0 + "\n" }.joined()
        )

        XCTAssertEqual(
            try EvalChildProcess.run(
                "/usr/bin/say", arguments: ["-v", "Albert", "hello"],
                proxy: proxyDirectory, timeout: .seconds(30)
            ),
            64
        )
    }

    func testEnvironmentReportListsKeysAndMasksHomeAndUser() {
        let report = EvalChildProcess.environmentReport(
            [
                "HOME": "/Users/alice", "TMPDIR": "/var/folders/x/T/", "PATH": "/usr/bin",
                "SECRET_TOKEN": "hunter2", "XPC_SERVICE_NAME": "0",
                "__CFBundleIdentifier": "com.example", "DYLD_LIBRARY_PATH": "/Users/alice/lib:/opt/alice",
            ],
            home: "/Users/alice", user: "alice"
        )
        XCTAssertEqual(
            report,
            [
                "keys: DYLD_LIBRARY_PATH HOME PATH SECRET_TOKEN TMPDIR XPC_SERVICE_NAME __CFBundleIdentifier",
                "DYLD_LIBRARY_PATH=<home>/lib:/opt/<user>",
                "HOME=<home>",
                "TMPDIR=/var/folders/x/T/",
                "XPC_SERVICE_NAME=0",
                "__CFBundleIdentifier=com.example",
            ]
        )
    }

    func testDirectRunWritesStandardOutputAndReportsStatus() throws {
        let output = try temporaryDirectory().appendingPathComponent("out.txt")
        let status = try EvalChildProcess.run(
            "/bin/sh", arguments: ["-c", "echo hello; exit 3"],
            standardOutput: output.path, discardStandardError: true, proxy: nil
        )
        XCTAssertEqual(status, 3)
        XCTAssertEqual(try String(contentsOf: output, encoding: .utf8), "hello\n")
    }
}
