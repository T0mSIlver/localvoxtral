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
    private struct State {
        var repositoryInfoURLs: [URL] = []
        var contentLengthProbes: [String] = []
        var downloadedFileNames: [String] = []
    }

    private let repositoryJSON: Data
    private let payloads: [String: Data]
    /// Files whose HEAD probe returns no Content-Length (the CDN behavior
    /// behind HF `resolve/` redirects); their size is only learned from the
    /// transfer itself via `onBytes`.
    private let headlessFiles: Set<String>
    private let state = Mutex(State())

    init(repositoryJSON: Data, payloads: [String: Data], headlessFiles: Set<String> = []) {
        self.repositoryJSON = repositoryJSON
        self.payloads = payloads
        self.headlessFiles = headlessFiles
    }

    var repositoryInfoURLs: [URL] { state.withLock { $0.repositoryInfoURLs } }
    var contentLengthProbes: [String] { state.withLock { $0.contentLengthProbes } }
    var downloadedFileNames: [String] { state.withLock { $0.downloadedFileNames } }

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

    func download(
        from url: URL,
        onBytes: @escaping @Sendable (Int64, Int64?) -> Void
    ) async throws -> (temporaryURL: URL, statusCode: Int) {
        let fileName = url.lastPathComponent
        state.withLock { $0.downloadedFileNames.append(fileName) }
        let payload = payloads[fileName] ?? Data()
        // Report the file in two halves so incremental-progress tests can
        // observe an in-flight (non-boundary) update.
        if !payload.isEmpty {
            onBytes(Int64(payload.count / 2), Int64(payload.count))
            onBytes(Int64(payload.count), Int64(payload.count))
        }
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("fake-hf-download-\(UUID().uuidString)")
        try payload.write(to: temporary)
        return (temporary, 200)
    }
}
