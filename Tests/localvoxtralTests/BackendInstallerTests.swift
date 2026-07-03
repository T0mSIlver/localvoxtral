import CryptoKit
import Foundation
import XCTest
@testable import localvoxtral

final class BackendInstallerTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDown() {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
        super.tearDown()
    }

    func testLayoutComputesExpectedDirectoriesAndEnvironment() throws {
        let root = makeTemporaryDirectory()
        let layout = BackendInstallLayout(root: root)

        XCTAssertEqual(layout.uvCache, root.appendingPathComponent("uv-cache", isDirectory: true))
        XCTAssertEqual(layout.pythonInstalls, root.appendingPathComponent("python", isDirectory: true))
        XCTAssertEqual(layout.tools, root.appendingPathComponent("tools", isDirectory: true))
        XCTAssertEqual(layout.toolBin, root.appendingPathComponent("bin", isDirectory: true))
        XCTAssertEqual(layout.downloads, root.appendingPathComponent("downloads", isDirectory: true))
        XCTAssertEqual(layout.environment["UV_CACHE_DIR"], layout.uvCache.path)
        XCTAssertEqual(layout.environment["UV_PYTHON_INSTALL_DIR"], layout.pythonInstalls.path)
        XCTAssertEqual(layout.environment["UV_TOOL_DIR"], layout.tools.path)
        XCTAssertEqual(layout.environment["UV_TOOL_BIN_DIR"], layout.toolBin.path)
    }

    @MainActor
    func testInstallHappyPathInvokesUVWithExpectedArgumentsEnvironmentAndWritesMarker() async throws {
        let root = makeTemporaryDirectory()
        let layout = BackendInstallLayout(root: root)
        let wheel = try writeWheel(named: "voxmlx fixture.whl", contents: "wheel-data")
        let spec = makeSpec(
            wheelURL: wheel,
            wheelSHA256: try sha256Hex(for: wheel),
            executableName: "voxmlx-serve"
        )
        let capture = root.appendingPathComponent("uv-capture.txt")
        let fakeUV = try writeFakeUV(
            in: root,
            capture: capture,
            executableNameToCreate: spec.executableName,
            exitCode: 0,
            stderrLines: ["uv stderr line"],
            stdoutLines: ["uv stdout line"]
        )
        let installer = BackendInstaller(
            layout: layout,
            uvLocator: FakeUVLocator(url: fakeUV)
        )

        var progressEvents: [BackendInstallProgress] = []
        try await installer.install(spec) { event in
            progressEvents.append(event)
        }

        let captureText = try String(contentsOf: capture, encoding: .utf8)
        XCTAssertTrue(captureText.contains("ARGS:tool|install|--python|3.12|--reinstall|"))
        XCTAssertTrue(captureText.contains("voxmlx[server] @ file://"))
        XCTAssertTrue(captureText.contains("/downloads/voxmlx%20fixture.whl"))
        XCTAssertTrue(captureText.contains("UV_CACHE_DIR=\(layout.uvCache.path)"))
        XCTAssertTrue(captureText.contains("UV_PYTHON_INSTALL_DIR=\(layout.pythonInstalls.path)"))
        XCTAssertTrue(captureText.contains("UV_TOOL_DIR=\(layout.tools.path)"))
        XCTAssertTrue(captureText.contains("UV_TOOL_BIN_DIR=\(layout.toolBin.path)"))
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: layout.toolBin.appendingPathComponent(spec.executableName).path))
        XCTAssertEqual(installer.installedVersion(of: spec), spec.version)
        XCTAssertFalse(installer.needsInstallOrUpdate(spec))
        XCTAssertTrue(progressEvents.contains(.downloading(fraction: nil)))
        XCTAssertTrue(progressEvents.contains(.downloading(fraction: 1)))
        XCTAssertTrue(progressEvents.contains(.verifying))
        XCTAssertTrue(progressEvents.contains(.installing(logLine: "uv stdout line")))
        XCTAssertTrue(progressEvents.contains(.installing(logLine: "uv stderr line")))
        XCTAssertEqual(progressEvents.last, .finished)
    }

    func testChecksumMismatchDeletesWheelAndDoesNotInvokeUV() async throws {
        let root = makeTemporaryDirectory()
        let layout = BackendInstallLayout(root: root)
        let wheel = try writeWheel(named: "bad.whl", contents: "bad-wheel")
        let spec = makeSpec(
            wheelURL: wheel,
            wheelSHA256: String(repeating: "0", count: 64),
            executableName: "voxmlx-serve"
        )
        let capture = root.appendingPathComponent("uv-capture.txt")
        let fakeUV = try writeFakeUV(
            in: root,
            capture: capture,
            executableNameToCreate: spec.executableName,
            exitCode: 0
        )
        let installer = BackendInstaller(
            layout: layout,
            uvLocator: FakeUVLocator(url: fakeUV)
        )

        do {
            try await installer.install(spec) { _ in }
            XCTFail("Expected checksum mismatch")
        } catch BackendInstallError.checksumMismatch(let expected, let actual) {
            XCTAssertEqual(expected, spec.wheelSHA256)
            XCTAssertEqual(actual, try sha256Hex(for: wheel))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: capture.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: layout.downloads.appendingPathComponent(wheel.lastPathComponent).path))
        XCTAssertNil(installer.installedVersion(of: spec))
    }

    func testUVFailureCarriesStderrTailAndDoesNotWriteMarker() async throws {
        let root = makeTemporaryDirectory()
        let layout = BackendInstallLayout(root: root)
        let wheel = try writeWheel(named: "voxmlx.whl", contents: "wheel-data")
        let spec = makeSpec(
            wheelURL: wheel,
            wheelSHA256: try sha256Hex(for: wheel),
            executableName: "voxmlx-serve"
        )
        let fakeUV = try writeFakeUV(
            in: root,
            capture: root.appendingPathComponent("uv-capture.txt"),
            executableNameToCreate: spec.executableName,
            exitCode: 7,
            stderrLines: (1...25).map { "stderr-\($0)" }
        )
        let installer = BackendInstaller(
            layout: layout,
            uvLocator: FakeUVLocator(url: fakeUV)
        )

        do {
            try await installer.install(spec) { _ in }
            XCTFail("Expected uv failure")
        } catch BackendInstallError.uvExited(let code, let stderrTail) {
            XCTAssertEqual(code, 7)
            let tailLines = stderrTail.split(separator: "\n").map(String.init)
            XCTAssertFalse(tailLines.contains("stderr-1"))
            XCTAssertTrue(tailLines.contains("stderr-6"))
            XCTAssertTrue(tailLines.contains("stderr-25"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertNil(installer.installedVersion(of: spec))
    }

    func testExecutableMissingAfterSuccessfulUVRunThrowsAndDoesNotWriteMarker() async throws {
        let root = makeTemporaryDirectory()
        let layout = BackendInstallLayout(root: root)
        let wheel = try writeWheel(named: "voxmlx.whl", contents: "wheel-data")
        let spec = makeSpec(
            wheelURL: wheel,
            wheelSHA256: try sha256Hex(for: wheel),
            executableName: "voxmlx-serve"
        )
        let fakeUV = try writeFakeUV(
            in: root,
            capture: root.appendingPathComponent("uv-capture.txt"),
            executableNameToCreate: nil,
            exitCode: 0
        )
        let installer = BackendInstaller(
            layout: layout,
            uvLocator: FakeUVLocator(url: fakeUV)
        )

        do {
            try await installer.install(spec) { _ in }
            XCTFail("Expected missing executable")
        } catch BackendInstallError.executableMissing(let url) {
            XCTAssertEqual(url, layout.toolBin.appendingPathComponent(spec.executableName))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertNil(installer.installedVersion(of: spec))
    }

    func testInstalledVersionAndNeedsInstallOrUpdateRoundTrip() async throws {
        let root = makeTemporaryDirectory()
        let layout = BackendInstallLayout(root: root)
        let wheel = try writeWheel(named: "voxmlx.whl", contents: "wheel-data")
        let spec = makeSpec(
            wheelURL: wheel,
            wheelSHA256: try sha256Hex(for: wheel),
            executableName: "voxmlx-serve"
        )
        let fakeUV = try writeFakeUV(
            in: root,
            capture: root.appendingPathComponent("uv-capture.txt"),
            executableNameToCreate: spec.executableName,
            exitCode: 0
        )
        let installer = BackendInstaller(
            layout: layout,
            uvLocator: FakeUVLocator(url: fakeUV)
        )

        XCTAssertNil(installer.installedVersion(of: spec))
        XCTAssertTrue(installer.needsInstallOrUpdate(spec))

        try await installer.install(spec) { _ in }

        XCTAssertEqual(installer.installedVersion(of: spec), spec.version)
        XCTAssertFalse(installer.needsInstallOrUpdate(spec))

        let newerSpec = makeSpec(
            version: "9.9.9",
            wheelURL: wheel,
            wheelSHA256: try sha256Hex(for: wheel),
            executableName: "voxmlx-serve"
        )
        XCTAssertTrue(installer.needsInstallOrUpdate(newerSpec))
    }

    private func makeTemporaryDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("localvoxtral-backend-tests-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        return directory
    }

    private func writeWheel(named name: String, contents: String) throws -> URL {
        let directory = makeTemporaryDirectory()
        let url = directory.appendingPathComponent(name)
        try contents.data(using: .utf8)!.write(to: url)
        return url
    }

    private func writeFakeUV(
        in directory: URL,
        capture: URL,
        executableNameToCreate: String?,
        exitCode: Int,
        stderrLines: [String] = [],
        stdoutLines: [String] = []
    ) throws -> URL {
        let url = directory.appendingPathComponent("uv")
        let createExecutableBlock: String
        if let executableNameToCreate {
            createExecutableBlock = """
            mkdir -p "$UV_TOOL_BIN_DIR"
            touch "$UV_TOOL_BIN_DIR/\(executableNameToCreate)"
            chmod +x "$UV_TOOL_BIN_DIR/\(executableNameToCreate)"
            """
        } else {
            createExecutableBlock = ":"
        }
        let stderrBlock = stderrLines.map { "echo '\($0)' >&2" }.joined(separator: "\n")
        let stdoutBlock = stdoutLines.map { "echo '\($0)'" }.joined(separator: "\n")
        let script = """
        #!/usr/bin/env bash
        set -euo pipefail
        {
          printf 'ARGS:'
          joined=''
          for arg in "$@"; do
            if [[ -n "$joined" ]]; then
              joined="${joined}|"
            fi
            joined="${joined}${arg}"
          done
          printf '%s\\n' "$joined"
          printf 'UV_CACHE_DIR=%s\\n' "$UV_CACHE_DIR"
          printf 'UV_PYTHON_INSTALL_DIR=%s\\n' "$UV_PYTHON_INSTALL_DIR"
          printf 'UV_TOOL_DIR=%s\\n' "$UV_TOOL_DIR"
          printf 'UV_TOOL_BIN_DIR=%s\\n' "$UV_TOOL_BIN_DIR"
        } > "\(capture.path)"
        \(stdoutBlock)
        \(stderrBlock)
        \(createExecutableBlock)
        exit \(exitCode)
        """
        try script.data(using: .utf8)!.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private func makeSpec(
        version: String = "1.2.3",
        wheelURL: URL,
        wheelSHA256: String,
        executableName: String
    ) -> ManagedBackendSpec {
        ManagedBackendSpec(
            id: "voxmlx",
            displayName: "voxmlx",
            version: version,
            requirementName: "voxmlx[server]",
            wheelURL: wheelURL,
            wheelSHA256: wheelSHA256,
            executableName: executableName,
            pythonVersion: "3.12",
            port: 8471
        )
    }

    private func sha256Hex(for url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        return SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

private struct FakeUVLocator: UVBinaryLocating {
    let url: URL?

    func uvBinaryURL() -> URL? {
        url
    }
}
