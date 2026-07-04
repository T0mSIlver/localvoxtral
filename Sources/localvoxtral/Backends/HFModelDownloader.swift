import Darwin
import Foundation

struct ModelDownloadProgress: Equatable, Sendable {
    var downloadedBytes: Int64
    var totalBytes: Int64?

    var fraction: Double? {
        guard let totalBytes, totalBytes > 0 else { return nil }
        return min(1, Double(downloadedBytes) / Double(totalBytes))
    }
}

struct ModelPreparationRequest: Equatable, Sendable {
    let backendID: String
    let displayName: String
    let repoID: String
    let includePatterns: [String]
}

protocol ModelPreparing: Sendable {
    func prepare(
        _ request: ModelPreparationRequest,
        progress: @MainActor @Sendable @escaping (ModelDownloadProgress) -> Void
    ) async throws
}

enum ModelDownloadError: LocalizedError, Sendable {
    case uvNotFound(URL)
    case downloaderReportedError(message: String, stderrTail: String)
    case noProgress(timeoutSeconds: Int, stderrTail: String)
    case processExited(code: Int32, stderrTail: String)

    var errorDescription: String? {
        switch self {
        case .uvNotFound(let url):
            return "Managed uv is missing at \(url.path)."
        case .downloaderReportedError(let message, _):
            return message.trimmed.isEmpty ? "Model download failed." : message
        case .noProgress(let timeoutSeconds, _):
            return "Model download made no progress for \(timeoutSeconds) seconds."
        case .processExited(let code, _):
            return "Model downloader exited with status \(code)."
        }
    }

    var technicalDetails: String? {
        switch self {
        case .uvNotFound:
            return nil
        case .downloaderReportedError(_, let stderrTail),
             .noProgress(_, let stderrTail),
             .processExited(_, let stderrTail):
            return stderrTail.trimmed.isEmpty ? nil : stderrTail
        }
    }
}

struct HFModelDownloader: ModelPreparing {
    private let layout: BackendInstallLayout
    private let uvLocator: any UVBinaryLocating
    private let fileManager: FileManager
    private let livenessTimeoutSeconds: Int

    init(
        layout: BackendInstallLayout = BackendInstallLayout(),
        uvLocator: (any UVBinaryLocating)? = nil,
        fileManager: FileManager = .default,
        livenessTimeoutSeconds: Int = 120
    ) {
        self.layout = layout
        self.uvLocator = uvLocator ?? UVBinaryLocator(layout: layout)
        self.fileManager = fileManager
        self.livenessTimeoutSeconds = livenessTimeoutSeconds
    }

    func prepare(
        _ request: ModelPreparationRequest,
        progress: @MainActor @Sendable @escaping (ModelDownloadProgress) -> Void
    ) async throws {
        try fileManager.createDirectory(at: layout.downloads, withIntermediateDirectories: true)
        // Resolve uv the same way BackendInstaller does (managed download,
        // then Homebrew/usr-local fallbacks) — machines that installed the
        // backends with a system uv never provision the managed binary.
        guard let uvBinary = uvLocator.uvBinaryURL() else {
            throw ModelDownloadError.uvNotFound(layout.managedUVBinary)
        }

        let scriptURL = layout.downloads.appendingPathComponent("hf_model_download.py")
        try Self.pythonDownloaderScript.write(to: scriptURL, atomically: true, encoding: .utf8)

        var arguments = [
            "run",
            "--python",
            "3.12",
            // Ceiling pins: deps resolve at run time per machine, and an
            // unbounded transitive resolve is how transformers 5.13 broke
            // mlx-lm in the field (2026-07-04). Raise deliberately.
            "--with",
            "huggingface_hub<2",
            "--with",
            "tqdm<5",
            "python",
            "-u",
            scriptURL.path,
            request.repoID,
        ]
        for pattern in request.includePatterns {
            arguments.append("--include")
            arguments.append(pattern)
        }

        let result = try await ModelDownloadProcess.run(
            executableURL: uvBinary,
            arguments: arguments,
            environment: processEnvironment(),
            livenessTimeoutSeconds: livenessTimeoutSeconds,
            progress: progress
        )
        if result.exitCode != 0 {
            throw ModelDownloadError.processExited(
                code: result.exitCode,
                stderrTail: result.stderrTail
            )
        }
    }

    private func processEnvironment() -> [String: String] {
        let inherited = ProcessInfo.processInfo.environment
        var environment: [String: String] = [:]
        for key in ["PATH", "HOME"] {
            if let value = inherited[key] {
                environment[key] = value
            }
        }
        // Deliberately leave Hugging Face cache variables unset so model
        // weights stay in the user's global HF cache, shared with other tools.
        environment.merge(layout.environment) { _, new in new }
        return environment
    }

    static let pythonDownloaderScript = #"""
import argparse
import json
import os
import sys
import time

from huggingface_hub import snapshot_download
from tqdm.auto import tqdm


def emit(payload):
    print(json.dumps(payload, separators=(",", ":")), flush=True)


def should_count_for_download(info):
    will_download = getattr(info, "will_download", None)
    if will_download is not None:
        return bool(will_download)
    is_cached = getattr(info, "is_cached", None)
    if is_cached is not None:
        return not bool(is_cached)
    return True


class JSONTqdm(tqdm):
    def __init__(self, *args, **kwargs):
        self._localvoxtral_reports_bytes = kwargs.get("unit") == "B"
        self._localvoxtral_last_emit_at = 0.0
        self._localvoxtral_emit_interval = self._emit_interval()
        kwargs["file"] = _NullTqdmFile()
        super().__init__(*args, **kwargs)

    def _emit_interval(self):
        value = os.environ.get("LOCALVOXTRAL_HF_EMIT_INTERVAL")
        if value is None:
            return 0.5
        try:
            return max(0.0, float(value))
        except ValueError:
            return 0.5

    def refresh(self, *args, **kwargs):
        return True

    def display(self, *args, **kwargs):
        return None

    def update(self, n=1):
        result = super().update(n)
        if not self._localvoxtral_reports_bytes:
            return result
        now = time.monotonic()
        total = self.total
        if (
            self._localvoxtral_emit_interval == 0
            or now - self._localvoxtral_last_emit_at >= self._localvoxtral_emit_interval
            or (total and self.n >= total)
        ):
            self._localvoxtral_last_emit_at = now
            emit({
                "event": "progress",
                "repo": ARGS.repo,
                "downloaded": int(self.n),
                "total": int(total) if total is not None else None,
            })
        return result


class _NullTqdmFile:
    def write(self, value):
        return len(value)

    def flush(self):
        pass


def resolve_total(repo, include_patterns):
    dry_run = snapshot_download(
        repo,
        allow_patterns=include_patterns,
        dry_run=True,
    )
    total = 0
    for info in dry_run:
        if should_count_for_download(info):
            total += int(getattr(info, "file_size", 0) or 0)
    return total


def main():
    total = resolve_total(ARGS.repo, ARGS.include)
    emit({"event": "total", "repo": ARGS.repo, "total": total})
    snapshot_download(
        ARGS.repo,
        allow_patterns=ARGS.include,
        tqdm_class=JSONTqdm,
    )
    emit({"event": "done", "repo": ARGS.repo})


parser = argparse.ArgumentParser()
parser.add_argument("repo")
parser.add_argument("--include", action="append", default=[])
ARGS = parser.parse_args()

try:
    main()
except Exception as exc:
    emit({"event": "error", "message": str(exc)})
    raise
"""#
}

extension HFModelDownloader: @unchecked Sendable {}

enum ModelDownloadJSONEvent: Equatable, Sendable {
    case total(repo: String, totalBytes: Int64)
    case progress(repo: String, downloadedBytes: Int64, totalBytes: Int64?)
    case done(repo: String)
    case error(message: String)
}

enum ModelDownloadJSONParser {
    static func parse(_ line: String) -> ModelDownloadJSONEvent? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let event = object["event"] as? String
        else { return nil }

        switch event {
        case "total":
            guard let repo = object["repo"] as? String,
                  let total = int64Value(object["total"])
            else { return nil }
            return .total(repo: repo, totalBytes: total)
        case "progress":
            guard let repo = object["repo"] as? String,
                  let downloaded = int64Value(object["downloaded"])
            else { return nil }
            return .progress(
                repo: repo,
                downloadedBytes: downloaded,
                totalBytes: int64Value(object["total"])
            )
        case "done":
            guard let repo = object["repo"] as? String else { return nil }
            return .done(repo: repo)
        case "error":
            guard let message = object["message"] as? String else { return nil }
            return .error(message: message)
        default:
            return nil
        }
    }

    private static func int64Value(_ value: Any?) -> Int64? {
        switch value {
        case let value as Int:
            return Int64(value)
        case let value as Int64:
            return value
        case let value as Double where value.isFinite:
            return Int64(value)
        case let value as NSNumber:
            return value.int64Value
        default:
            return nil
        }
    }
}

struct ModelDownloadProcessResult: Equatable, Sendable {
    let exitCode: Int32
    let stderrTail: String
}

final class ModelDownloadProcess {
    static func run(
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        livenessTimeoutSeconds: Int,
        progress: @MainActor @Sendable @escaping (ModelDownloadProgress) -> Void
    ) async throws -> ModelDownloadProcessResult {
        let processBox = CancellableProcessBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let thread = Thread {
                    do {
                        let result = try runSynchronously(
                            executableURL: executableURL,
                            arguments: arguments,
                            environment: environment,
                            livenessTimeoutSeconds: livenessTimeoutSeconds,
                            progress: progress,
                            processBox: processBox
                        )
                        continuation.resume(returning: result)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
                thread.name = "localvoxtral-model-download"
                thread.start()
            }
        } onCancel: {
            processBox.requestCancel()
        }
    }

    private static func runSynchronously(
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        livenessTimeoutSeconds: Int,
        progress: @MainActor @Sendable @escaping (ModelDownloadProgress) -> Void,
        processBox: CancellableProcessBox
    ) throws -> ModelDownloadProcessResult {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = environment

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        let collector = ModelDownloadLineCollector(progress: progress)
        let stdoutReader = PipeLineReader(fileHandle: stdout.fileHandleForReading) { line in
            collector.recordStdout(line)
        }
        let stderrReader = PipeLineReader(fileHandle: stderr.fileHandleForReading) { line in
            collector.recordStderr(line)
        }

        try process.run()
        processBox.set(process)
        stdoutReader.start()
        stderrReader.start()

        while process.isRunning {
            if processBox.wasCancelled {
                processBox.terminateRunningProcess()
                break
            }
            if let message = collector.downloaderErrorMessage() {
                processBox.terminateRunningProcess()
                process.waitUntilExit()
                finishReaders(stdoutReader: stdoutReader, stderrReader: stderrReader)
                throw ModelDownloadError.downloaderReportedError(
                    message: message,
                    stderrTail: collector.stderrTail()
                )
            }
            if collector.secondsSinceLastEvent() >= livenessTimeoutSeconds {
                processBox.terminateRunningProcess()
                process.waitUntilExit()
                finishReaders(stdoutReader: stdoutReader, stderrReader: stderrReader)
                throw ModelDownloadError.noProgress(
                    timeoutSeconds: livenessTimeoutSeconds,
                    stderrTail: collector.stderrTail()
                )
            }
            Thread.sleep(forTimeInterval: 0.25)
        }

        process.waitUntilExit()
        finishReaders(stdoutReader: stdoutReader, stderrReader: stderrReader)
        processBox.clear(process)

        if processBox.wasCancelled {
            throw CancellationError()
        }
        if let message = collector.downloaderErrorMessage() {
            throw ModelDownloadError.downloaderReportedError(
                message: message,
                stderrTail: collector.stderrTail()
            )
        }

        return ModelDownloadProcessResult(
            exitCode: process.terminationStatus,
            stderrTail: collector.stderrTail()
        )
    }

    private static func finishReaders(
        stdoutReader: PipeLineReader,
        stderrReader: PipeLineReader
    ) {
        stdoutReader.waitUntilFinished()
        stderrReader.waitUntilFinished()
    }
}

private final class CancellableProcessBox: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    var wasCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func set(_ process: Process) {
        lock.lock()
        self.process = process
        lock.unlock()
    }

    func clear(_ process: Process) {
        lock.lock()
        if self.process === process {
            self.process = nil
        }
        lock.unlock()
    }

    func requestCancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    func terminateRunningProcess() {
        lock.lock()
        let process = process
        lock.unlock()

        guard let process, process.isRunning else { return }
        process.terminate()
        for _ in 0..<20 where process.isRunning {
            Thread.sleep(forTimeInterval: 0.1)
        }
        if process.isRunning {
            Darwin.kill(process.processIdentifier, SIGKILL)
        }
    }
}

private final class ModelDownloadLineCollector: @unchecked Sendable {
    private let lock = NSLock()
    private let progress: @MainActor @Sendable (ModelDownloadProgress) -> Void
    private var stderrLines: [String] = []
    private var lastEventAt = Date()
    private var lastTotalBytes: Int64?
    private var errorMessage: String?

    init(progress: @MainActor @Sendable @escaping (ModelDownloadProgress) -> Void) {
        self.progress = progress
    }

    func recordStdout(_ line: String) {
        guard let event = ModelDownloadJSONParser.parse(line) else { return }
        markEvent()
        switch event {
        case .total(_, let totalBytes):
            lastTotalBytes = totalBytes
            emit(ModelDownloadProgress(downloadedBytes: 0, totalBytes: totalBytes))
        case .progress(_, let downloadedBytes, let totalBytes):
            if let totalBytes {
                lastTotalBytes = totalBytes
            }
            emit(ModelDownloadProgress(downloadedBytes: downloadedBytes, totalBytes: totalBytes ?? lastTotalBytes))
        case .done:
            if let lastTotalBytes {
                emit(ModelDownloadProgress(downloadedBytes: lastTotalBytes, totalBytes: lastTotalBytes))
            }
        case .error(let message):
            lock.lock()
            errorMessage = message
            lock.unlock()
        }
    }

    func recordStderr(_ line: String) {
        lock.lock()
        stderrLines.append(line)
        if stderrLines.count > 20 {
            stderrLines.removeFirst(stderrLines.count - 20)
        }
        lock.unlock()
    }

    func stderrTail() -> String {
        lock.lock()
        defer { lock.unlock() }
        return stderrLines.joined(separator: "\n")
    }

    func downloaderErrorMessage() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return errorMessage
    }

    func secondsSinceLastEvent() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return Int(Date().timeIntervalSince(lastEventAt))
    }

    private func markEvent() {
        lock.lock()
        lastEventAt = Date()
        lock.unlock()
    }

    private func emit(_ event: ModelDownloadProgress) {
        let semaphore = DispatchSemaphore(value: 0)
        Task { @MainActor [progress] in
            progress(event)
            semaphore.signal()
        }
        semaphore.wait()
    }
}
