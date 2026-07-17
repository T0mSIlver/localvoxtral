import Darwin
import Foundation
import Synchronization

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
    /// Pinned commit, or nil to track the repo's `main` (custom repo ids).
    let revision: String?
    let includePatterns: [String]

    init(
        backendID: String,
        displayName: String,
        repoID: String,
        revision: String? = nil,
        includePatterns: [String]
    ) {
        self.backendID = backendID
        self.displayName = displayName
        self.repoID = repoID
        self.revision = revision
        self.includePatterns = includePatterns
    }
}

protocol ModelPreparing: Sendable {
    func prepare(
        _ request: ModelPreparationRequest,
        progress: @MainActor @Sendable @escaping (ModelDownloadProgress) -> Void
    ) async throws
}

enum ModelDownloadError: LocalizedError, Sendable {
    case repositoryRequestFailed(repoID: String, statusCode: Int)
    case resolvedRevisionMismatch(expected: String, actual: String)
    case noMatchingFiles(repoID: String)
    case invalidRepositoryPath(String)
    case fileRequestFailed(path: String, statusCode: Int)
    case transport(message: String, detail: String?)

    var errorDescription: String? {
        switch self {
        case .repositoryRequestFailed(let repoID, let statusCode):
            return "Model repository request failed for \(repoID) (HTTP \(statusCode))."
        case .resolvedRevisionMismatch(let expected, let actual):
            return "Model revision mismatch: expected \(expected), resolved \(actual)."
        case .noMatchingFiles(let repoID):
            return "Model repository \(repoID) contains none of the required files."
        case .invalidRepositoryPath(let path):
            return "Model repository returned an unsafe file path: \(path)."
        case .fileRequestFailed(let path, let statusCode):
            return "Model file download failed for \(path) (HTTP \(statusCode))."
        case .transport(let message, _):
            return message.trimmed.isEmpty ? "Model download failed." : message
        }
    }

    var technicalDetails: String? {
        if case .transport(_, let detail) = self { return detail }
        return errorDescription
    }
}

struct HFModelRepositoryInfo: Equatable, Sendable {
    let sha: String
    let fileNames: [String]
    /// Exact byte sizes from the repo API (`?blobs=true`), keyed by file name.
    /// The authoritative source for the download total: available before the
    /// first byte moves, unlike HEAD probes (which the CDN may refuse) or
    /// transfer-reported sizes (which arrive only as each file starts).
    let sizesByFileName: [String: Int64]
}

protocol HFModelDownloadTransport: Sendable {
    func repositoryInfo(from url: URL) async throws -> (data: Data, statusCode: Int)
    func contentLength(of url: URL) async throws -> Int64?
    /// Download one file. `onBytes(received, expected)` reports cumulative
    /// bytes received for THIS file as the transfer runs (expected is nil when
    /// the server sends no length); required for live progress on multi-GB
    /// checkpoints, where a completion-only API would leave the UI frozen on
    /// "Checking model..." for the whole fetch (field-hit 2026-07-17).
    func download(
        from url: URL,
        onBytes: @escaping @Sendable (Int64, Int64?) -> Void
    ) async throws -> (temporaryURL: URL, statusCode: Int)
}

struct URLSessionHFModelDownloadTransport: HFModelDownloadTransport {
    func repositoryInfo(from url: URL) async throws -> (data: Data, statusCode: Int) {
        let (data, response) = try await URLSession.shared.data(from: url)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    func contentLength(of url: URL) async throws -> Int64? {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse,
              (200..<300).contains(response.statusCode)
        else { return nil }
        return response.expectedContentLength > 0 ? response.expectedContentLength : nil
    }

    func download(
        from url: URL,
        onBytes: @escaping @Sendable (Int64, Int64?) -> Void
    ) async throws -> (temporaryURL: URL, statusCode: Int) {
        let delegate = ProgressReportingDownloadDelegate(onBytes: onBytes)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                delegate.begin(session: session, url: url, continuation: continuation)
            }
        } onCancel: {
            delegate.cancel()
        }
    }
}

/// Delegate for one download task: relays byte-level progress and hands the
/// finished file back through a continuation. `didFinishDownloadingTo`'s file
/// is deleted the moment that callback returns, so it is moved to a stable
/// temporary path synchronously inside the callback.
private final class ProgressReportingDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private struct State {
        var continuation: CheckedContinuation<(temporaryURL: URL, statusCode: Int), Error>?
        var task: URLSessionDownloadTask?
        var movedURL: URL?
        var moveError: Error?
    }

    private let onBytes: @Sendable (Int64, Int64?) -> Void
    private let state = Mutex(State())

    init(onBytes: @escaping @Sendable (Int64, Int64?) -> Void) {
        self.onBytes = onBytes
    }

    func begin(
        session: URLSession,
        url: URL,
        continuation: CheckedContinuation<(temporaryURL: URL, statusCode: Int), Error>
    ) {
        let task = session.downloadTask(with: url)
        state.withLock {
            $0.continuation = continuation
            $0.task = task
        }
        task.resume()
    }

    func cancel() {
        state.withLock { $0.task }?.cancel()
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        onBytes(totalBytesWritten, totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("localvoxtral-hf-download-\(UUID().uuidString)")
        do {
            try FileManager.default.moveItem(at: location, to: destination)
            state.withLock { $0.movedURL = destination }
        } catch {
            state.withLock { $0.moveError = error }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let (continuation, movedURL, moveError) = state.withLock {
            let values = ($0.continuation, $0.movedURL, $0.moveError)
            $0.continuation = nil
            return values
        }
        guard let continuation else { return }
        if let error {
            continuation.resume(throwing: error)
        } else if let moveError {
            continuation.resume(throwing: moveError)
        } else if let movedURL {
            let statusCode = (task.response as? HTTPURLResponse)?.statusCode ?? 0
            continuation.resume(returning: (movedURL, statusCode))
        } else {
            continuation.resume(throwing: URLError(.cannotWriteToFile))
        }
    }
}

struct HFModelDownloader: ModelPreparing {
    private struct RepositoryResponse: Decodable {
        struct Sibling: Decodable {
            let rfilename: String
            let size: Int64?
        }
        let sha: String
        let siblings: [Sibling]
    }

    private let cacheRoot: URL
    private let transport: any HFModelDownloadTransport
    private let fileManager: FileManager
    /// Minimum received-byte delta between in-flight progress reports for one
    /// file. Bounds MainActor hops to a few hundred over a multi-GB fetch;
    /// tests inject 1 to observe every callback.
    private let progressByteGranularity: Int64

    init(
        cacheRoot: URL? = nil,
        transport: any HFModelDownloadTransport = URLSessionHFModelDownloadTransport(),
        fileManager: FileManager = .default,
        progressByteGranularity: Int64 = 8_388_608
    ) {
        self.cacheRoot = cacheRoot ?? Self.defaultCacheRoot()
        self.transport = transport
        self.fileManager = fileManager
        self.progressByteGranularity = progressByteGranularity
    }

    func prepare(
        _ request: ModelPreparationRequest,
        progress: @MainActor @Sendable @escaping (ModelDownloadProgress) -> Void
    ) async throws {
        do {
            let info = try await repositoryInfo(for: request)
            let wanted = info.fileNames.filter { fileName in
                request.includePatterns.contains { fnmatch($0, fileName, 0) == 0 }
            }
            guard !wanted.isEmpty else {
                throw ModelDownloadError.noMatchingFiles(repoID: request.repoID)
            }

            let snapshot = snapshotDirectory(repoID: request.repoID, revision: info.sha)
            try fileManager.createDirectory(at: snapshot, withIntermediateDirectories: true)
            let missing = try wanted.filter { fileName in
                let destination = try safeDestination(for: fileName, under: snapshot)
                return !fileManager.fileExists(atPath: destination.path)
            }

            // Prefer the repo API's exact sizes (one call, already made);
            // HEAD-probe only files the API left sizeless.
            var sizes: [String: Int64] = [:]
            for fileName in missing {
                if let size = info.sizesByFileName[fileName] {
                    sizes[fileName] = size
                    continue
                }
                try Task.checkCancellation()
                if let size = try await transport.contentLength(
                    of: Self.fileURL(repoID: request.repoID, revision: info.sha, fileName: fileName)
                ) {
                    sizes[fileName] = size
                }
            }
            // Dynamic total: the HEAD probe can come back without a length
            // (HF `resolve/` redirects to a CDN), which would leave the UI
            // bar-less for the whole fetch. Each file's expected size also
            // arrives from the transfer itself the moment its download
            // starts, so fold that in — the total (and the determinate
            // progress bar) becomes available as soon as every missing file
            // has a size from either source.
            let missingCount = missing.count
            let knownSizes = Mutex<[String: Int64]>(sizes)
            let effectiveTotal: @Sendable () -> Int64? = {
                knownSizes.withLock { known in
                    known.count == missingCount ? known.values.reduce(0, +) : nil
                }
            }
            // Monotonic delivery gate, checked at delivery time on the main
            // actor: throttled in-flight reports hop over as unstructured
            // tasks, so without the gate a stale lower value could land after
            // a newer higher one and make the bar jump backwards.
            let deliveredFloor = Mutex<Int64>(-1)
            let deliver: @MainActor @Sendable (ModelDownloadProgress) -> Void = { snapshot in
                let shouldDeliver = deliveredFloor.withLock { floor in
                    guard snapshot.downloadedBytes > floor else { return false }
                    floor = snapshot.downloadedBytes
                    return true
                }
                if shouldDeliver { progress(snapshot) }
            }
            await Self.report(
                ModelDownloadProgress(downloadedBytes: 0, totalBytes: effectiveTotal()),
                deliver
            )

            var downloaded: Int64 = 0
            for fileName in missing {
                try Task.checkCancellation()
                let source = Self.fileURL(
                    repoID: request.repoID,
                    revision: info.sha,
                    fileName: fileName
                )
                let completedBase = downloaded
                let granularity = progressByteGranularity
                let lastReported = Mutex<Int64>(0)
                let result = try await transport.download(from: source) { received, expected in
                    if let expected {
                        knownSizes.withLock { known in
                            if known[fileName] == nil { known[fileName] = expected }
                        }
                    }
                    let shouldReport = lastReported.withLock { last in
                        guard received - last >= granularity else { return false }
                        last = received
                        return true
                    }
                    guard shouldReport else { return }
                    let snapshot = ModelDownloadProgress(
                        downloadedBytes: completedBase + received,
                        totalBytes: effectiveTotal()
                    )
                    Task { @MainActor in deliver(snapshot) }
                }
                guard (200..<300).contains(result.statusCode) else {
                    throw ModelDownloadError.fileRequestFailed(
                        path: fileName,
                        statusCode: result.statusCode
                    )
                }
                let destination = try safeDestination(for: fileName, under: snapshot)
                try fileManager.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                if fileManager.fileExists(atPath: destination.path) {
                    try fileManager.removeItem(at: destination)
                }
                try fileManager.moveItem(at: result.temporaryURL, to: destination)
                // The on-disk size is authoritative once the file landed; it
                // also completes the dynamic total for files whose transfer
                // reported no expected length.
                let actualSize = sizes[fileName] ?? fileSize(at: destination)
                knownSizes.withLock { $0[fileName] = actualSize }
                downloaded += actualSize
                await Self.report(
                    ModelDownloadProgress(downloadedBytes: downloaded, totalBytes: effectiveTotal()),
                    deliver
                )
            }

            if request.revision == nil {
                let refs = repositoryDirectory(repoID: request.repoID)
                    .appendingPathComponent("refs", isDirectory: true)
                try fileManager.createDirectory(at: refs, withIntermediateDirectories: true)
                try Data("\(info.sha)\n".utf8).write(
                    to: refs.appendingPathComponent("main"),
                    options: .atomic
                )
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ModelDownloadError {
            throw error
        } catch {
            throw ModelDownloadError.transport(
                message: "Model download failed.",
                detail: error.localizedDescription
            )
        }
    }

    static func defaultCacheRoot(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        if let hubCache = environment["HF_HUB_CACHE"], !hubCache.isEmpty {
            return URL(fileURLWithPath: hubCache, isDirectory: true)
        }
        if let hfHome = environment["HF_HOME"], !hfHome.isEmpty {
            return URL(fileURLWithPath: hfHome, isDirectory: true)
                .appendingPathComponent("hub", isDirectory: true)
        }
        return home
            .appendingPathComponent(".cache", isDirectory: true)
            .appendingPathComponent("huggingface", isDirectory: true)
            .appendingPathComponent("hub", isDirectory: true)
    }

    static func repositoryInfoURL(repoID: String, revision: String?) -> URL {
        // blobs=true adds exact per-file byte sizes to the sibling list, so
        // the aggregate download total is known before any transfer starts.
        URL(string: "https://huggingface.co/api/models/\(repoID)/revision/\(revision ?? "main")?blobs=true")!
    }

    static func fileURL(repoID: String, revision: String, fileName: String) -> URL {
        URL(string: "https://huggingface.co/\(repoID)/resolve/\(revision)/\(fileName)")!
    }

    private func repositoryInfo(for request: ModelPreparationRequest) async throws -> HFModelRepositoryInfo {
        let result = try await transport.repositoryInfo(
            from: Self.repositoryInfoURL(repoID: request.repoID, revision: request.revision)
        )
        guard result.statusCode == 200 else {
            throw ModelDownloadError.repositoryRequestFailed(
                repoID: request.repoID,
                statusCode: result.statusCode
            )
        }
        let response = try JSONDecoder().decode(RepositoryResponse.self, from: result.data)
        if let revision = request.revision, response.sha != revision {
            throw ModelDownloadError.resolvedRevisionMismatch(
                expected: revision,
                actual: response.sha
            )
        }
        var sizesByFileName: [String: Int64] = [:]
        for sibling in response.siblings {
            if let size = sibling.size {
                sizesByFileName[sibling.rfilename] = size
            }
        }
        return HFModelRepositoryInfo(
            sha: response.sha,
            fileNames: response.siblings.map(\.rfilename),
            sizesByFileName: sizesByFileName
        )
    }

    private func repositoryDirectory(repoID: String) -> URL {
        cacheRoot.appendingPathComponent(
            "models--" + repoID.replacingOccurrences(of: "/", with: "--"),
            isDirectory: true
        )
    }

    private func snapshotDirectory(repoID: String, revision: String) -> URL {
        repositoryDirectory(repoID: repoID)
            .appendingPathComponent("snapshots", isDirectory: true)
            .appendingPathComponent(revision, isDirectory: true)
    }

    private func safeDestination(for fileName: String, under snapshot: URL) throws -> URL {
        let root = snapshot.standardizedFileURL
        let destination = root.appendingPathComponent(fileName).standardizedFileURL
        let rootPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard destination.path.hasPrefix(rootPrefix) else {
            throw ModelDownloadError.invalidRepositoryPath(fileName)
        }
        return destination
    }

    private func fileSize(at url: URL) -> Int64 {
        let attributes = try? fileManager.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }

    @MainActor
    private static func report(
        _ event: ModelDownloadProgress,
        _ progress: @MainActor @Sendable (ModelDownloadProgress) -> Void
    ) {
        progress(event)
    }
}

extension HFModelDownloader: @unchecked Sendable {}
