import CryptoKit
import Foundation

enum BackendInstallProgress: Equatable, Sendable {
    case downloading(fraction: Double?)
    case verifying
    case installing(logLine: String)
    case finished
}

enum BackendInstallError: LocalizedError, Sendable {
    case uvNotFound
    case downloadFailed(String)
    case checksumMismatch(expected: String, actual: String)
    case uvExtractionFailed(String)
    case uvExited(code: Int32, stderrTail: String)
    case executableMissing(URL)

    var errorDescription: String? {
        switch self {
        case .uvNotFound:
            return "Unable to find or install uv. Expected managed uv or Homebrew uv at /opt/homebrew/bin/uv or /usr/local/bin/uv."
        case .downloadFailed(let message):
            return "Download failed: \(message)"
        case .checksumMismatch(let expected, let actual):
            return "Downloaded artifact checksum mismatch. Expected \(expected), got \(actual)."
        case .uvExtractionFailed(let message):
            return "uv archive extraction failed: \(message)"
        case .uvExited(let code, let stderrTail):
            return "uv exited with status \(code): \(stderrTail)"
        case .executableMissing(let url):
            return "Backend executable was not created by uv: \(url.path)"
        }
    }
}

protocol BackendInstalling: Sendable {
    func needsInstallOrUpdate(_ spec: ManagedBackendSpec) -> Bool
    func install(
        _ spec: ManagedBackendSpec,
        progress: @MainActor @Sendable @escaping (BackendInstallProgress) -> Void
    ) async throws
}

struct BackendInstaller: BackendInstalling {
    private let layout: BackendInstallLayout
    private let uvLocator: any UVBinaryLocating
    private let uvDistribution: UVDistribution
    private let fileManager: FileManager

    init(
        layout: BackendInstallLayout = BackendInstallLayout(),
        uvLocator: (any UVBinaryLocating)? = nil,
        uvDistribution: UVDistribution = .pinned,
        fileManager: FileManager = .default
    ) {
        self.layout = layout
        self.uvLocator = uvLocator ?? UVBinaryLocator(layout: layout)
        self.uvDistribution = uvDistribution
        self.fileManager = fileManager
    }

    func installedVersion(of spec: ManagedBackendSpec) -> String? {
        guard let marker = try? readInstalledMarker() else {
            return nil
        }
        return marker[spec.id]
    }

    func needsInstallOrUpdate(_ spec: ManagedBackendSpec) -> Bool {
        installedVersion(of: spec) != spec.version
    }

    func install(
        _ spec: ManagedBackendSpec,
        progress: @MainActor @Sendable @escaping (BackendInstallProgress) -> Void
    ) async throws {
        try createLayoutDirectories()
        let uvURL = try await resolveUVBinary(progress: progress)
        let wheelURL = try await downloadWheel(for: spec, progress: progress)

        await Self.report(.verifying, progress)
        let actualSHA256 = try sha256Hex(for: wheelURL)
        guard actualSHA256 == spec.wheelSHA256 else {
            try? fileManager.removeItem(at: wheelURL)
            throw BackendInstallError.checksumMismatch(
                expected: spec.wheelSHA256,
                actual: actualSHA256
            )
        }

        let requirement = "\(spec.requirementName) @ \(wheelURL.absoluteString)"
        let result = try await UVToolProcess.run(
            uvURL: uvURL,
            arguments: ["tool", "install", "--python", spec.pythonVersion, "--reinstall", requirement],
            environment: processEnvironment(),
            progress: progress
        )
        if result.exitCode != 0 {
            throw BackendInstallError.uvExited(
                code: result.exitCode,
                stderrTail: result.stderrTail
            )
        }

        let executableURL = layout.toolBin.appendingPathComponent(spec.executableName)
        guard fileManager.isExecutableFile(atPath: executableURL.path) else {
            throw BackendInstallError.executableMissing(executableURL)
        }

        try writeInstalledVersion(spec.version, for: spec.id)
        await Self.report(.finished, progress)
    }

    private var installedMarkerURL: URL {
        layout.root.appendingPathComponent("installed.json")
    }

    private func createLayoutDirectories() throws {
        for directory in [
            layout.root,
            layout.uvCache,
            layout.uvBinaryDirectory,
            layout.pythonInstalls,
            layout.tools,
            layout.toolBin,
            layout.downloads,
        ] {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    private func readInstalledMarker() throws -> [String: String] {
        guard fileManager.fileExists(atPath: installedMarkerURL.path) else {
            return [:]
        }
        let data = try Data(contentsOf: installedMarkerURL)
        return (try JSONSerialization.jsonObject(with: data) as? [String: String]) ?? [:]
    }

    private func writeInstalledVersion(_ version: String, for backendID: String) throws {
        try fileManager.createDirectory(at: layout.root, withIntermediateDirectories: true)
        var marker = try readInstalledMarker()
        marker[backendID] = version
        let data = try JSONSerialization.data(withJSONObject: marker, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: installedMarkerURL, options: .atomic)
    }

    private func processEnvironment() -> [String: String] {
        let inherited = ProcessInfo.processInfo.environment
        var environment: [String: String] = [:]
        for key in ["PATH", "HOME"] {
            if let value = inherited[key] {
                environment[key] = value
            }
        }
        environment.merge(layout.environment) { _, new in new }
        return environment
    }

    private func resolveUVBinary(
        progress: @MainActor @Sendable @escaping (BackendInstallProgress) -> Void
    ) async throws -> URL {
        if let uvURL = uvLocator.uvBinaryURL() {
            return uvURL
        }

        try await provisionManagedUV(progress: progress)
        guard fileManager.isExecutableFile(atPath: layout.managedUVBinary.path) else {
            throw BackendInstallError.uvNotFound
        }
        return layout.managedUVBinary
    }

    private func provisionManagedUV(
        progress: @MainActor @Sendable @escaping (BackendInstallProgress) -> Void
    ) async throws {
        await Self.report(
            .installing(logLine: "Downloading uv \(uvDistribution.version)"),
            progress
        )
        let tarballURL = try await downloadArtifact(
            from: uvDistribution.tarballURL,
            to: layout.downloads.appendingPathComponent(uvDistribution.tarballURL.lastPathComponent),
            progress: progress
        )

        await Self.report(.verifying, progress)
        let actualSHA256 = try sha256Hex(for: tarballURL)
        guard actualSHA256 == uvDistribution.tarballSHA256 else {
            try? fileManager.removeItem(at: tarballURL)
            throw BackendInstallError.checksumMismatch(
                expected: uvDistribution.tarballSHA256,
                actual: actualSHA256
            )
        }

        await Self.report(
            .installing(logLine: "Installing uv \(uvDistribution.version)"),
            progress
        )
        let temporaryDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("localvoxtral-uv-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: temporaryDirectory)
        }

        let extractionResult = try await TarExtractionProcess.extract(
            tarballURL: tarballURL,
            destinationDirectory: temporaryDirectory,
            memberPath: uvDistribution.archiveBinaryPath
        )
        guard extractionResult.exitCode == 0 else {
            throw BackendInstallError.uvExtractionFailed(extractionResult.stderrTail)
        }

        let extractedUV = temporaryDirectory.appendingPathComponent(uvDistribution.archiveBinaryPath)
        guard fileManager.fileExists(atPath: extractedUV.path) else {
            throw BackendInstallError.uvExtractionFailed(
                "Archive did not contain \(uvDistribution.archiveBinaryPath)."
            )
        }

        if fileManager.fileExists(atPath: layout.managedUVBinary.path) {
            try fileManager.removeItem(at: layout.managedUVBinary)
        }
        try fileManager.copyItem(at: extractedUV, to: layout.managedUVBinary)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: layout.managedUVBinary.path)
    }

    private func downloadWheel(
        for spec: ManagedBackendSpec,
        progress: @MainActor @Sendable @escaping (BackendInstallProgress) -> Void
    ) async throws -> URL {
        try await downloadArtifact(
            from: spec.wheelURL,
            to: layout.downloads.appendingPathComponent(spec.wheelURL.lastPathComponent),
            progress: progress
        )
    }

    private func downloadArtifact(
        from sourceURL: URL,
        to destination: URL,
        progress: @MainActor @Sendable @escaping (BackendInstallProgress) -> Void
    ) async throws -> URL {
        await Self.report(.downloading(fraction: nil), progress)

        if sourceURL.isFileURL {
            do {
                if fileManager.fileExists(atPath: destination.path) {
                    try fileManager.removeItem(at: destination)
                }
                try fileManager.copyItem(at: sourceURL, to: destination)
                await Self.report(.downloading(fraction: 1), progress)
                return destination
            } catch {
                throw BackendInstallError.downloadFailed(error.localizedDescription)
            }
        }

        do {
            let (bytes, response) = try await URLSession.shared.bytes(from: sourceURL)
            let expectedLength = response.expectedContentLength
            var data = Data()
            var downloadedByteCount: Int64 = 0
            var lastReportedBucket: Int64 = -1

            for try await byte in bytes {
                data.append(byte)
                downloadedByteCount += 1
                if expectedLength > 0 {
                    let bucket = downloadedByteCount / 262_144
                    if bucket != lastReportedBucket || downloadedByteCount == expectedLength {
                        lastReportedBucket = bucket
                        await Self.report(
                            .downloading(
                                fraction: min(1, Double(downloadedByteCount) / Double(expectedLength))
                            ),
                            progress
                        )
                    }
                }
            }
            try data.write(to: destination, options: .atomic)
            if expectedLength > 0 {
                await Self.report(.downloading(fraction: 1), progress)
            }
            return destination
        } catch let error as BackendInstallError {
            throw error
        } catch {
            throw BackendInstallError.downloadFailed(error.localizedDescription)
        }
    }

    private func sha256Hex(for url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    @MainActor
    private static func report(
        _ event: BackendInstallProgress,
        _ progress: @MainActor @Sendable (BackendInstallProgress) -> Void
    ) {
        progress(event)
    }
}

extension BackendInstaller: @unchecked Sendable {}

private struct UVToolProcessResult: Sendable {
    let exitCode: Int32
    let stderrTail: String
}

private struct TarExtractionProcessResult: Sendable {
    let exitCode: Int32
    let stderrTail: String
}

private final class TarExtractionProcess {
    static func extract(
        tarballURL: URL,
        destinationDirectory: URL,
        memberPath: String
    ) async throws -> TarExtractionProcessResult {
        try await Task.detached {
            try extractSynchronously(
                tarballURL: tarballURL,
                destinationDirectory: destinationDirectory,
                memberPath: memberPath
            )
        }.value
    }

    private static func extractSynchronously(
        tarballURL: URL,
        destinationDirectory: URL,
        memberPath: String
    ) throws -> TarExtractionProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = [
            "-xzf",
            tarballURL.path,
            "-C",
            destinationDirectory.path,
            memberPath,
        ]

        let stderr = Pipe()
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
        let stderrText = String(data: stderrData, encoding: .utf8) ?? ""
        return TarExtractionProcessResult(
            exitCode: process.terminationStatus,
            stderrTail: stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}

private final class UVToolProcess {
    static func run(
        uvURL: URL,
        arguments: [String],
        environment: [String: String],
        progress: @MainActor @Sendable @escaping (BackendInstallProgress) -> Void
    ) async throws -> UVToolProcessResult {
        try await Task.detached {
            try runSynchronously(
                uvURL: uvURL,
                arguments: arguments,
                environment: environment,
                progress: progress
            )
        }.value
    }

    private static func runSynchronously(
        uvURL: URL,
        arguments: [String],
        environment: [String: String],
        progress: @MainActor @Sendable @escaping (BackendInstallProgress) -> Void
    ) throws -> UVToolProcessResult {
        let process = Process()
        process.executableURL = uvURL
        process.arguments = arguments
        process.environment = environment

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        let lineCollector = ProcessLineCollector(progress: progress)
        let stdoutReader = PipeLineReader(fileHandle: stdout.fileHandleForReading) { line in
            lineCollector.recordStdout(line)
        }
        let stderrReader = PipeLineReader(fileHandle: stderr.fileHandleForReading) { line in
            lineCollector.recordStderr(line)
        }

        try process.run()
        stdoutReader.start()
        stderrReader.start()
        process.waitUntilExit()
        stdout.fileHandleForReading.closeFile()
        stderr.fileHandleForReading.closeFile()
        stdoutReader.waitUntilFinished()
        stderrReader.waitUntilFinished()

        return UVToolProcessResult(
            exitCode: process.terminationStatus,
            stderrTail: lineCollector.stderrTail()
        )
    }
}

private final class ProcessLineCollector: @unchecked Sendable {
    private let lock = NSLock()
    private let progress: @MainActor @Sendable (BackendInstallProgress) -> Void
    private var stderrLines: [String] = []

    init(progress: @MainActor @Sendable @escaping (BackendInstallProgress) -> Void) {
        self.progress = progress
    }

    func recordStdout(_ line: String) {
        emit(line)
    }

    func recordStderr(_ line: String) {
        lock.lock()
        stderrLines.append(line)
        if stderrLines.count > 20 {
            stderrLines.removeFirst(stderrLines.count - 20)
        }
        lock.unlock()
        emit(line)
    }

    func stderrTail() -> String {
        lock.lock()
        defer { lock.unlock() }
        return stderrLines.joined(separator: "\n")
    }

    private func emit(_ line: String) {
        let semaphore = DispatchSemaphore(value: 0)
        Task { @MainActor [progress] in
            progress(.installing(logLine: line))
            semaphore.signal()
        }
        semaphore.wait()
    }
}

// Internal (not private) so the crash regression tests can drive it directly.
final class PipeLineReader: @unchecked Sendable {
    private let fileHandle: FileHandle
    // Captured once while the handle is known-valid; the read loop uses the
    // raw descriptor so no NSFileHandle method can raise mid-read.
    private let descriptor: Int32
    private let onLine: @Sendable (String) -> Void
    private let state = PipeLineReaderState()
    private var thread: Thread?

    init(fileHandle: FileHandle, onLine: @Sendable @escaping (String) -> Void) {
        self.fileHandle = fileHandle
        self.descriptor = fileHandle.fileDescriptor
        self.onLine = onLine
    }

    func start() {
        let descriptor = descriptor
        let fileHandle = fileHandle
        let onLine = onLine
        let state = state
        let thread = Thread {
            // Retain the FileHandle for the loop's lifetime so the descriptor
            // is not closed-and-reused underneath the reads.
            withExtendedLifetime(fileHandle) {}
            var buffer = Data()
            while true {
                let chunk = POSIXPipeRead.nextChunk(fromDescriptor: descriptor)
                if chunk.isEmpty {
                    break
                }
                buffer.append(chunk)
                while let newlineIndex = buffer.firstIndex(of: 0x0A) {
                    let lineData = buffer[..<newlineIndex]
                    buffer.removeSubrange(...newlineIndex)
                    if let line = String(data: lineData, encoding: .utf8), !line.isEmpty {
                        onLine(line)
                    }
                }
            }
            if !buffer.isEmpty,
               let line = String(data: buffer, encoding: .utf8),
               !line.isEmpty
            {
                onLine(line)
            }
            state.markFinished()
        }
        self.thread = thread
        thread.start()
    }

    func waitUntilFinished() {
        state.waitUntilFinished()
    }
}

private final class PipeLineReaderState: @unchecked Sendable {
    private let condition = NSCondition()
    private var isFinished = false

    func markFinished() {
        condition.lock()
        isFinished = true
        condition.signal()
        condition.unlock()
    }

    func waitUntilFinished() {
        condition.lock()
        while !isFinished {
            condition.wait()
        }
        condition.unlock()
    }
}
