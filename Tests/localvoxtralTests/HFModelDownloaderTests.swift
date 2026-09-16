import Foundation
import Synchronization
import XCTest

@testable import localvoxtral

@MainActor
final class HFModelDownloaderTests: XCTestCase {
    func testDefaultCacheRootMatchesHuggingFaceEnvironmentPrecedence() {
        let home = URL(fileURLWithPath: "/Users/tester", isDirectory: true)
        XCTAssertEqual(
            HFModelDownloader.defaultCacheRoot(
                environment: ["HF_HUB_CACHE": "/custom/hub", "HF_HOME": "/ignored"],
                home: home
            ).path,
            "/custom/hub"
        )
        XCTAssertEqual(
            HFModelDownloader.defaultCacheRoot(environment: ["HF_HOME": "/custom/hf"], home: home).path,
            "/custom/hf/hub"
        )
        XCTAssertEqual(
            HFModelDownloader.defaultCacheRoot(environment: [:], home: home).path,
            "/Users/tester/.cache/huggingface/hub"
        )
    }

    func testPinnedPreparationDownloadsOnlyMatchingFilesAtExactRevision() async throws {
        let cache = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: cache) }
        let pin = "0123456789abcdef0123456789abcdef01234567"
        let transport = FakeHFModelDownloadTransport(
            repositoryJSON: repositoryJSON(
                sha: pin,
                files: ["config.json", "model.safetensors", "notes.md"]
            ),
            payloads: [
                "config.json": Data("config".utf8),
                "model.safetensors": Data("weights".utf8),
            ]
        )
        let downloader = HFModelDownloader(cacheRoot: cache, transport: transport)
        var progress: [ModelDownloadProgress] = []

        try await downloader.prepare(
            ModelPreparationRequest(
                backendID: "speechd",
                displayName: "Dictation engine",
                repoID: "org/model",
                revision: pin,
                includePatterns: ["config.json", "model*.safetensors"]
            )
        ) { progress.append($0) }

        XCTAssertEqual(
            transport.repositoryInfoURLs,
            [HFModelDownloader.repositoryInfoURL(repoID: "org/model", revision: pin)]
        )
        XCTAssertEqual(Set(transport.downloadedFileNames), ["config.json", "model.safetensors"])
        XCTAssertFalse(transport.downloadedFileNames.contains("notes.md"))
        let snapshot = cache
            .appendingPathComponent("models--org--model/snapshots/\(pin)", isDirectory: true)
        XCTAssertEqual(
            try String(contentsOf: snapshot.appendingPathComponent("config.json"), encoding: .utf8),
            "config"
        )
        XCTAssertEqual(
            try String(contentsOf: snapshot.appendingPathComponent("model.safetensors"), encoding: .utf8),
            "weights"
        )
        XCTAssertEqual(
            progress,
            [
                ModelDownloadProgress(downloadedBytes: 0, totalBytes: 13),
                ModelDownloadProgress(downloadedBytes: 6, totalBytes: 13),
                ModelDownloadProgress(downloadedBytes: 13, totalBytes: 13),
            ]
        )
    }

    /// Regression (field-hit 2026-07-17): a single multi-gigabyte file must
    /// surface in-flight progress. The completion-only transport reported
    /// bytes only at whole-file boundaries, so the UI sat on "Checking
    /// model..." for the entire 2.5 GB fetch.
    func testDownloadReportsInFlightProgressWithinASingleFile() async throws {
        let cache = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: cache) }
        let pin = "0123456789abcdef0123456789abcdef01234567"
        let transport = FakeHFModelDownloadTransport(
            repositoryJSON: repositoryJSON(sha: pin, files: ["model.safetensors"]),
            payloads: ["model.safetensors": Data("weights-payload".utf8)]
        )
        let downloader = HFModelDownloader(
            cacheRoot: cache,
            transport: transport,
            progressByteGranularity: 1
        )
        var progress: [ModelDownloadProgress] = []

        try await downloader.prepare(
            ModelPreparationRequest(
                backendID: "speechd",
                displayName: "Dictation engine",
                repoID: "org/model",
                revision: pin,
                includePatterns: ["model*.safetensors"]
            )
        ) { progress.append($0) }
        // In-flight reports hop to the main actor as unstructured tasks;
        // drain them before asserting.
        for _ in 0..<10 { await Task.yield() }

        let bytes = progress.map(\.downloadedBytes)
        XCTAssertEqual(bytes.first, 0)
        XCTAssertEqual(bytes.last, 15)
        XCTAssertEqual(bytes, bytes.sorted(), "delivered progress must be monotonic")
        XCTAssertEqual(Set(bytes).count, bytes.count, "no duplicate deliveries")
        XCTAssertTrue(
            bytes.contains { $0 > 0 && $0 < 15 },
            "expected an in-flight report between 0 and total, got \(bytes)"
        )
    }

    /// When the HEAD probe returns no Content-Length (CDN behavior), the
    /// total — and therefore the determinate progress bar — must still become
    /// available from the transfer's own expected-size callback.
    func testTotalIsLearnedFromTransferWhenHEADProbeHasNoLength() async throws {
        let cache = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: cache) }
        let pin = "0123456789abcdef0123456789abcdef01234567"
        let transport = FakeHFModelDownloadTransport(
            repositoryJSON: repositoryJSON(sha: pin, files: ["model.safetensors"]),
            payloads: ["model.safetensors": Data("weights-payload".utf8)],
            headlessFiles: ["model.safetensors"]
        )
        let downloader = HFModelDownloader(
            cacheRoot: cache,
            transport: transport,
            progressByteGranularity: 1
        )
        var progress: [ModelDownloadProgress] = []

        try await downloader.prepare(
            ModelPreparationRequest(
                backendID: "speechd",
                displayName: "Dictation engine",
                repoID: "org/model",
                revision: pin,
                includePatterns: ["model*.safetensors"]
            )
        ) { progress.append($0) }
        for _ in 0..<10 { await Task.yield() }

        // The pre-download report cannot know a total (HEAD gave none)...
        XCTAssertEqual(progress.first, ModelDownloadProgress(downloadedBytes: 0, totalBytes: nil))
        // ...but every report from the transfer onward carries the learned
        // total, and the final report is exact.
        XCTAssertEqual(progress.last, ModelDownloadProgress(downloadedBytes: 15, totalBytes: 15))
        XCTAssertTrue(
            progress.dropFirst().allSatisfy { $0.totalBytes == 15 },
            "expected all post-start reports to carry the learned total, got \(progress)"
        )
        XCTAssertTrue(
            progress.contains { $0.downloadedBytes > 0 && $0.downloadedBytes < 15 && $0.fraction != nil },
            "expected an in-flight report with a computable fraction, got \(progress)"
        )
    }

    /// The repo API (`?blobs=true`) carries exact per-file sizes, so the total
    /// — and the determinate bar — must be available from the very first
    /// report, with no per-file HEAD probes at all.
    func testRepoAPISizesProvideTheTotalUpfrontWithoutHEADProbes() async throws {
        let cache = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: cache) }
        let pin = "0123456789abcdef0123456789abcdef01234567"
        let transport = FakeHFModelDownloadTransport(
            repositoryJSON: repositoryJSON(
                sha: pin,
                files: ["model.safetensors"],
                sizes: ["model.safetensors": 15]
            ),
            payloads: ["model.safetensors": Data("weights-payload".utf8)]
        )
        let downloader = HFModelDownloader(
            cacheRoot: cache,
            transport: transport,
            progressByteGranularity: 1
        )
        var progress: [ModelDownloadProgress] = []

        try await downloader.prepare(
            ModelPreparationRequest(
                backendID: "speechd",
                displayName: "Dictation engine",
                repoID: "org/model",
                revision: pin,
                includePatterns: ["model*.safetensors"]
            )
        ) { progress.append($0) }
        for _ in 0..<10 { await Task.yield() }

        XCTAssertEqual(progress.first, ModelDownloadProgress(downloadedBytes: 0, totalBytes: 15))
        XCTAssertTrue(
            transport.contentLengthProbes.isEmpty,
            "API sizes must make HEAD probes unnecessary, probed \(transport.contentLengthProbes)"
        )
        XCTAssertEqual(progress.last, ModelDownloadProgress(downloadedBytes: 15, totalBytes: 15))
    }

    func testUnpinnedPreparationTracksMainAndWritesResolvedRef() async throws {
        let cache = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: cache) }
        let resolved = "abcdefabcdefabcdefabcdefabcdefabcdefabcd"
        let transport = FakeHFModelDownloadTransport(
            repositoryJSON: repositoryJSON(sha: resolved, files: ["config.json"]),
            payloads: ["config.json": Data("{}".utf8)]
        )
        let downloader = HFModelDownloader(cacheRoot: cache, transport: transport)

        try await downloader.prepare(
            ModelPreparationRequest(
                backendID: "polishd",
                displayName: "Polishing engine",
                repoID: "org/custom",
                includePatterns: ["*.json"]
            )
        ) { _ in }

        XCTAssertEqual(
            transport.repositoryInfoURLs,
            [HFModelDownloader.repositoryInfoURL(repoID: "org/custom", revision: nil)]
        )
        let ref = cache.appendingPathComponent("models--org--custom/refs/main")
        XCTAssertEqual(try String(contentsOf: ref, encoding: .utf8), "\(resolved)\n")
    }

    func testPinnedPreparationRejectsResolvedRevisionMismatchBeforeDownloading() async throws {
        let cache = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: cache) }
        let transport = FakeHFModelDownloadTransport(
            repositoryJSON: repositoryJSON(sha: "moved", files: ["config.json"]),
            payloads: ["config.json": Data()]
        )
        let downloader = HFModelDownloader(cacheRoot: cache, transport: transport)

        do {
            try await downloader.prepare(
                ModelPreparationRequest(
                    backendID: "speechd",
                    displayName: "Dictation engine",
                    repoID: "org/model",
                    revision: "pinned",
                    includePatterns: ["*.json"]
                )
            ) { _ in }
            XCTFail("expected revision mismatch")
        } catch let error as ModelDownloadError {
            guard case .resolvedRevisionMismatch(let expected, let actual) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(expected, "pinned")
            XCTAssertEqual(actual, "moved")
        }
        XCTAssertTrue(transport.downloadedFileNames.isEmpty)
    }

    func testRepositoryPathCannotEscapeSnapshotRoot() async throws {
        let cache = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: cache) }
        let transport = FakeHFModelDownloadTransport(
            repositoryJSON: repositoryJSON(sha: "pin", files: ["../outside.json"]),
            payloads: ["outside.json": Data()]
        )
        let downloader = HFModelDownloader(cacheRoot: cache, transport: transport)

        do {
            try await downloader.prepare(
                ModelPreparationRequest(
                    backendID: "speechd",
                    displayName: "Dictation engine",
                    repoID: "org/model",
                    revision: "pin",
                    includePatterns: ["*.json"]
                )
            ) { _ in }
            XCTFail("expected unsafe path rejection")
        } catch let error as ModelDownloadError {
            guard case .invalidRepositoryPath(let path) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(path, "../outside.json")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.appendingPathComponent("outside.json").path))
    }

    // MARK: - Pause (keep the bytes) vs cancel (drop them)

    /// Pause cancels the transfer mid-file and the bytes it salvaged must come
    /// back to the transport on the NEXT prepare of that same URL — otherwise
    /// "pause" would silently mean "start the multi-GB file again".
    func testPauseRetainsResumeDataAndTheNextPrepareHandsItBackForTheSameFile() async throws {
        let cache = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: cache) }
        let pin = "0123456789abcdef0123456789abcdef01234567"
        let transport = makePausableTransport(pin: pin)
        let downloader = HFModelDownloader(
            cacheRoot: cache,
            transport: transport,
            progressByteGranularity: 1
        )
        let request = pausableRequest(pin: pin)

        try await pause(downloader, request: request, transport: transport)

        let fileURL = HFModelDownloader.fileURL(
            repoID: "org/model",
            revision: pin,
            fileName: "model.safetensors"
        )
        XCTAssertEqual(
            transport.retainedResumeData(for: fileURL),
            FakeHFModelDownloadTransport.resumeBytes(for: "model.safetensors")
        )
        let snapshot = cache
            .appendingPathComponent("models--org--model/snapshots/\(pin)", isDirectory: true)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: snapshot.appendingPathComponent("model.safetensors").path
            ),
            "an unfinished file must not land in the snapshot directory"
        )

        // Resume.
        try await downloader.prepare(request) { _ in }

        XCTAssertEqual(
            transport.attempts,
            [
                FakeHFModelDownloadTransport.DownloadAttempt(
                    fileName: "model.safetensors",
                    resumeData: nil
                ),
                FakeHFModelDownloadTransport.DownloadAttempt(
                    fileName: "model.safetensors",
                    resumeData: FakeHFModelDownloadTransport.resumeBytes(for: "model.safetensors")
                ),
            ]
        )
        XCTAssertEqual(
            try String(
                contentsOf: snapshot.appendingPathComponent("model.safetensors"),
                encoding: .utf8
            ),
            "weights-payload"
        )
        XCTAssertNil(
            transport.retainedResumeData(for: fileURL),
            "a file that landed whole leaves nothing to resume from"
        )
    }

    /// Cancel is the other half of the contract: the retained bytes go, and the
    /// next prepare starts that file from zero.
    func testDiscardingPartialDownloadsMakesTheNextPrepareStartFromZero() async throws {
        let cache = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: cache) }
        let pin = "0123456789abcdef0123456789abcdef01234567"
        let transport = makePausableTransport(pin: pin)
        let downloader = HFModelDownloader(
            cacheRoot: cache,
            transport: transport,
            progressByteGranularity: 1
        )
        let request = pausableRequest(pin: pin)

        try await pause(downloader, request: request, transport: transport)
        downloader.discardPartialDownloads(for: request)

        // Swept by repo prefix, so every revision of that repo is covered.
        XCTAssertEqual(
            transport.discardedPrefixes,
            ["https://huggingface.co/org/model/resolve/"]
        )
        XCTAssertNil(
            transport.retainedResumeData(
                for: HFModelDownloader.fileURL(
                    repoID: "org/model",
                    revision: pin,
                    fileName: "model.safetensors"
                )
            )
        )

        try await downloader.prepare(request) { _ in }

        XCTAssertEqual(
            transport.attempts.map(\.resumeData),
            [nil, nil],
            "a cancelled download must not be silently continued"
        )
    }

    /// A cancelled transfer must reach `BackendManager` as a `CancellationError`.
    /// URLSession reports it as `URLError(.cancelled)`, and everything above
    /// this seam distinguishes "the user paused" from "the download failed" by
    /// catching `CancellationError` — get this wrong and Pause renders as a
    /// failure, then as Stopped, with no Resume button.
    func testCancellingMidTransferThrowsCancellationNotATransportFailure() async throws {
        let cache = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: cache) }
        let pin = "0123456789abcdef0123456789abcdef01234567"
        let transport = makePausableTransport(pin: pin)
        let downloader = HFModelDownloader(
            cacheRoot: cache,
            transport: transport,
            progressByteGranularity: 1
        )
        let request = pausableRequest(pin: pin)

        let paused = Task { try await downloader.prepare(request) { _ in } }
        await transport.waitUntilDownloadStarted()
        paused.cancel()

        do {
            try await paused.value
            XCTFail("expected the cancelled prepare to throw")
        } catch is CancellationError {
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }
    }

    /// The mapping above must stay narrow: a transport error that is NOT a
    /// cancellation still has to surface as a failure the UI can report.
    func testNonCancellationTransportErrorStillSurfacesAsAModelDownloadFailure() async throws {
        let cache = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: cache) }
        let pin = "0123456789abcdef0123456789abcdef01234567"
        let transport = FakeHFModelDownloadTransport(
            repositoryJSON: repositoryJSON(sha: pin, files: ["model.safetensors"]),
            payloads: [:],
            downloadFailure: URLError(.timedOut)
        )
        let downloader = HFModelDownloader(cacheRoot: cache, transport: transport)

        do {
            try await downloader.prepare(pausableRequest(pin: pin)) { _ in }
            XCTFail("expected the failing prepare to throw")
        } catch let error as ModelDownloadError {
            guard case .transport = error else {
                return XCTFail("unexpected ModelDownloadError: \(error)")
            }
        } catch {
            XCTFail("expected ModelDownloadError.transport, got \(error)")
        }
    }

    private func makePausableTransport(pin: String) -> FakeHFModelDownloadTransport {
        FakeHFModelDownloadTransport(
            repositoryJSON: repositoryJSON(
                sha: pin,
                files: ["model.safetensors"],
                sizes: ["model.safetensors": 15]
            ),
            payloads: ["model.safetensors": Data("weights-payload".utf8)],
            pausableFiles: ["model.safetensors"]
        )
    }

    private func pausableRequest(pin: String) -> ModelPreparationRequest {
        ModelPreparationRequest(
            backendID: "speechd",
            displayName: "Dictation engine",
            repoID: "org/model",
            revision: pin,
            includePatterns: ["model*.safetensors"]
        )
    }

    /// Runs a prepare up to the middle of its file and cancels it, which is
    /// what `BackendManager.pauseModelDownload` does to the ensure task.
    private func pause(
        _ downloader: HFModelDownloader,
        request: ModelPreparationRequest,
        transport: FakeHFModelDownloadTransport
    ) async throws {
        let paused = Task { try await downloader.prepare(request) { _ in } }
        await transport.waitUntilDownloadStarted()
        paused.cancel()
        do {
            try await paused.value
            XCTFail("expected the paused prepare to cancel")
        } catch is CancellationError {
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("HFModelDownloaderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func repositoryJSON(
        sha: String,
        files: [String],
        sizes: [String: Int64] = [:]
    ) -> Data {
        let siblings = files.map { file -> [String: Any] in
            var sibling: [String: Any] = ["rfilename": file]
            if let size = sizes[file] { sibling["size"] = size }
            return sibling
        }
        return try! JSONSerialization.data(withJSONObject: ["sha": sha, "siblings": siblings])
    }
}

private final class FakeHFModelDownloadTransport: HFModelDownloadTransport, @unchecked Sendable {
    /// One `download` call, with the resume data (if any) the downloader handed
    /// back for that file.
    struct DownloadAttempt: Equatable {
        let fileName: String
        let resumeData: Data?
    }

    private struct State {
        var repositoryInfoURLs: [URL] = []
        var contentLengthProbes: [String] = []
        var attempts: [DownloadAttempt] = []
        var resumeDataByURL: [String: Data] = [:]
        var discardedPrefixes: [String] = []
        var pendingPausableFiles: Set<String> = []
        var downloadStartedContinuation: CheckedContinuation<Void, Never>?
        var pauseContinuation: CheckedContinuation<Void, Error>?
    }

    private let repositoryJSON: Data
    private let payloads: [String: Data]
    /// Files whose HEAD probe returns no Content-Length (the CDN behavior
    /// behind HF `resolve/` redirects); their size is only learned from the
    /// transfer itself via `onBytes`.
    private let headlessFiles: Set<String>
    /// Thrown instead of completing a transfer, for the non-cancellation
    /// failure path.
    private let downloadFailure: Error?
    private let state = Mutex(State())

    init(
        repositoryJSON: Data,
        payloads: [String: Data],
        headlessFiles: Set<String> = [],
        /// Files whose FIRST transfer suspends mid-file until the task is
        /// cancelled and then leaves resume data behind, standing in for
        /// `URLSessionDownloadTask.cancel(byProducingResumeData:)`.
        pausableFiles: Set<String> = [],
        downloadFailure: Error? = nil
    ) {
        self.repositoryJSON = repositoryJSON
        self.payloads = payloads
        self.headlessFiles = headlessFiles
        self.downloadFailure = downloadFailure
        state.withLock { $0.pendingPausableFiles = pausableFiles }
    }

    var repositoryInfoURLs: [URL] { state.withLock { $0.repositoryInfoURLs } }
    var contentLengthProbes: [String] { state.withLock { $0.contentLengthProbes } }
    var attempts: [DownloadAttempt] { state.withLock { $0.attempts } }
    var downloadedFileNames: [String] { state.withLock { $0.attempts.map(\.fileName) } }
    var discardedPrefixes: [String] { state.withLock { $0.discardedPrefixes } }

    static func resumeBytes(for fileName: String) -> Data {
        Data("resume-\(fileName)".utf8)
    }

    /// The domain the REAL transport reports. URLSession completes a cancelled
    /// download task with `URLError(.cancelled)` (NSURLErrorDomain -999), never
    /// with `CancellationError`, and everything above `prepare` tells "the user
    /// paused" from "the download failed" by catching `CancellationError`.
    static let cancellationError = URLError(.cancelled)

    private func retainResumeData(for url: URL, fileName: String) {
        state.withLock { $0.resumeDataByURL[url.absoluteString] = Self.resumeBytes(for: fileName) }
    }

    private func cancelTransfer(url: URL, fileName: String) {
        let continuation: CheckedContinuation<Void, Error>? = state.withLock {
            // What URLSession's cancel(byProducingResumeData:) leaves behind,
            // and what the real transport then retains.
            $0.resumeDataByURL[url.absoluteString] = Self.resumeBytes(for: fileName)
            let parked = $0.pauseContinuation
            $0.pauseContinuation = nil
            return parked
        }
        continuation?.resume(throwing: Self.cancellationError)
    }

    func repositoryInfo(from url: URL) async throws -> (data: Data, statusCode: Int) {
        state.withLock { $0.repositoryInfoURLs.append(url) }
        return (repositoryJSON, 200)
    }

    func contentLength(of url: URL) async throws -> Int64? {
        let fileName = url.lastPathComponent
        state.withLock { $0.contentLengthProbes.append(fileName) }
        guard !headlessFiles.contains(fileName) else { return nil }
        return Int64(payloads[fileName]?.count ?? 0)
    }

    func retainedResumeData(for url: URL) -> Data? {
        state.withLock { $0.resumeDataByURL[url.absoluteString] }
    }

    func discardResumeData(withURLPrefix prefix: String) {
        state.withLock { state in
            state.discardedPrefixes.append(prefix)
            for key in state.resumeDataByURL.keys where key.hasPrefix(prefix) {
                state.resumeDataByURL[key] = nil
            }
        }
    }

    func download(
        from url: URL,
        resumeData: Data?,
        onBytes: @escaping @Sendable (Int64, Int64?) -> Void
    ) async throws -> (temporaryURL: URL, statusCode: Int) {
        let fileName = url.lastPathComponent
        let started: CheckedContinuation<Void, Never>? = state.withLock {
            $0.attempts.append(DownloadAttempt(fileName: fileName, resumeData: resumeData))
            let continuation = $0.downloadStartedContinuation
            $0.downloadStartedContinuation = nil
            return continuation
        }
        started?.resume()

        if let downloadFailure { throw downloadFailure }

        let payload = payloads[fileName] ?? Data()
        // Report the file in two halves so incremental-progress tests can
        // observe an in-flight (non-boundary) update.
        if !payload.isEmpty {
            onBytes(Int64(payload.count / 2), Int64(payload.count))
        }

        let shouldPause = state.withLock { $0.pendingPausableFiles.remove(fileName) != nil }
        if shouldPause {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    // Same orphan guard as FakeModelPreparer: the cancellation
                    // handler can run before this continuation is parked. Both
                    // exits go through `cancelTransfer` so the error domain
                    // does not depend on which side of that race wins — it
                    // used to, and one path throwing CancellationError hid the
                    // defect the other path exposed.
                    let orphaned: CheckedContinuation<Void, Error>? = state.withLock {
                        if Task.isCancelled { return continuation }
                        $0.pauseContinuation = continuation
                        return nil
                    }
                    if let orphaned {
                        retainResumeData(for: url, fileName: fileName)
                        orphaned.resume(throwing: Self.cancellationError)
                    }
                }
            } onCancel: {
                self.cancelTransfer(url: url, fileName: fileName)
            }
        }

        if !payload.isEmpty {
            onBytes(Int64(payload.count), Int64(payload.count))
        }
        // A whole file landed: nothing is left to resume from.
        state.withLock { $0.resumeDataByURL[url.absoluteString] = nil }
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("fake-hf-download-\(UUID().uuidString)")
        try payload.write(to: temporary)
        return (temporary, 200)
    }

    func waitUntilDownloadStarted() async {
        await withCheckedContinuation { continuation in
            let alreadyStarted: Bool = state.withLock {
                if $0.attempts.isEmpty {
                    $0.downloadStartedContinuation = continuation
                    return false
                }
                return true
            }
            if alreadyStarted {
                continuation.resume()
            }
        }
    }
}
