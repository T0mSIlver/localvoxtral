import Foundation
import XCTest

@testable import localvoxtral

/// Launching the packaged polishing helper and provisioning its model, shared
/// by the polishd integration suite and the speculative-decoding bench.
enum PolishModelSnapshot {
    /// Marker written after the last file lands (see ensurePolishModelCached).
    static let provisionedSentinel = ".localvoxtral-provisioned"

    /// Generous because the first request after a cold Metal JIT cache can
    /// pay kernel-compilation time on top of model load.
    static let helperReadyTimeout: TimeInterval = 300

    static func isProvisioned(_ snapshot: URL) -> Bool {
        FileManager.default.fileExists(
            atPath: snapshot.appendingPathComponent(provisionedSentinel).path
        )
            && FileManager.default.fileExists(
                atPath: snapshot.appendingPathComponent("config.json").path
            )
    }
}

@MainActor
extension XCTestCase {
    struct PolishModelProvisioningError: Error, CustomStringConvertible {
        let description: String
    }

    /// The helper never downloads (missing model = hard error by design), so
    /// the suite provisions the shared HF cache itself when the model is
    /// absent — the same cache layout + include patterns as the app's
    /// HFModelDownloader, idempotent, ~3.3 GB for the default 4B (once per
    /// build host/user).
    /// Provisioning failures are test FAILURES, not skips: this suite only
    /// runs when explicitly enabled, and a green skip would hide broken infra.
    func ensurePolishModelCached(_ repoID: String) async throws {
        let cacheRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/huggingface/hub")
        let repoDir = cacheRoot.appendingPathComponent(
            "models--" + repoID.replacingOccurrences(of: "/", with: "--")
        )
        let snapshotsDir = repoDir.appendingPathComponent("snapshots")

        // Provision the revision the app PINS (catalog), not whatever main
        // points at — the helper now refuses any other snapshot, and tracking
        // main is exactly how an upstream index rewrite broke this suite
        // (2026-07-14). Custom repo ids (no catalog entry) still track main.
        let pinnedRevision = PolishModelCatalog.option(forRepoID: repoID)?.revision

        // Completeness marker is a sentinel INSIDE the snapshot, written LAST
        // below. Keying on config.json alone would let a cancelled
        // half-download (config present, weights missing) poison the cache
        // into a permanently-failing suite. It is deliberately not refs/main:
        // hf_hub writes no ref for a sha-pinned download, so a ref-keyed marker
        // would (a) miss a cache the app itself populated and (b) force this
        // suite to point the SHARED cache's main ref at a non-head commit,
        // lying to every other tool on the host.
        if let pinnedRevision {
            if PolishModelSnapshot.isProvisioned(snapshotsDir.appendingPathComponent(pinnedRevision)) {
                return
            }
        } else if let revision = try? String(
            contentsOf: repoDir.appendingPathComponent("refs/main"),
            encoding: .utf8
        )
        .trimmingCharacters(in: .whitespacesAndNewlines),
            !revision.isEmpty,
            PolishModelSnapshot.isProvisioned(snapshotsDir.appendingPathComponent(revision))
        {
            return
        }

        print("polishd integration: downloading \(repoID) into \(cacheRoot.path)")
        struct RepoInfo: Decodable {
            struct Sibling: Decodable { let rfilename: String }
            let sha: String
            let siblings: [Sibling]
        }
        let apiURL = URL(
            string:
                "https://huggingface.co/api/models/\(repoID)/revision/\(pinnedRevision ?? "main")"
        )!
        let (infoData, infoResponse) = try await URLSession.shared.data(from: apiURL)
        guard (infoResponse as? HTTPURLResponse)?.statusCode == 200 else {
            throw PolishModelProvisioningError(
                description: "HF API unreachable for \(repoID): \(infoResponse)"
            )
        }
        let info = try JSONDecoder().decode(RepoInfo.self, from: infoData)
        if let pinnedRevision, info.sha != pinnedRevision {
            throw PolishModelProvisioningError(
                description:
                    "HF resolved \(repoID)@\(pinnedRevision) to sha \(info.sha) — pin is not a commit"
            )
        }

        // Same include patterns as BackendManager.modelPreparationRequest.
        let patterns = [
            "*.json", "model*.safetensors", "*.py", "tokenizer.model",
            "*.tiktoken", "tiktoken.model", "*.txt", "*.jsonl", "*.jinja",
        ]
        let wanted = info.siblings.map(\.rfilename).filter { name in
            patterns.contains { fnmatch($0, name, 0) == 0 }
        }
        guard !wanted.isEmpty else {
            throw PolishModelProvisioningError(description: "HF listing for \(repoID) matched no files")
        }

        let snapshotDir = snapshotsDir.appendingPathComponent(info.sha)
        try FileManager.default.createDirectory(
            at: snapshotDir, withIntermediateDirectories: true
        )
        for name in wanted {
            let destination = snapshotDir.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: destination.path) { continue }
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            let source = URL(
                string: "https://huggingface.co/\(repoID)/resolve/\(info.sha)/\(name)"
            )!
            let (temporary, response) = try await URLSession.shared.download(from: source)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw PolishModelProvisioningError(description: "download failed for \(name): \(response)")
            }
            try FileManager.default.moveItem(at: temporary, to: destination)
        }

        // An unpinned (custom) repo is still resolved through refs/main by the
        // helper, so it needs the ref; a pinned one must not touch it.
        if pinnedRevision == nil {
            let refsDir = repoDir.appendingPathComponent("refs")
            try FileManager.default.createDirectory(at: refsDir, withIntermediateDirectories: true)
            try Data("\(info.sha)\n".utf8).write(to: repoDir.appendingPathComponent("refs/main"))
        }
        // Written LAST: everything above is resumable, this says "complete".
        try Data().write(to: snapshotDir.appendingPathComponent(PolishModelSnapshot.provisionedSentinel))
        print("polishd integration: model provisioned (\(wanted.count) files)")
    }

    /// Spawns the helper and waits for its stderr readiness line
    /// ("ready on 127.0.0.1:<port>"), which carries the ephemeral port when
    /// launched with --port 0. Event-driven via the same descriptor-safe
    /// PipeLineReader the app's installer uses (never
    /// FileHandle.availableData — PR #60).
    func launchPolishHelper(
        binary: URL,
        model: String,
        extraArguments: [String] = []
    ) async throws -> (process: Process, port: UInt16, stderrLog: PolishHelperLineLog) {
        let process = Process()
        process.executableURL = binary
        // Mirror BackendManager.arguments(for:): the app pins the revision, so
        // the suite must exercise the helper with the pin attached.
        var arguments = ["--model", model, "--port", "0"]
        if let revision = PolishModelCatalog.option(forRepoID: model)?.revision {
            arguments.append(contentsOf: ["--model-revision", revision])
        }
        process.arguments = arguments + extraArguments

        let stderr = Pipe()
        process.standardError = stderr
        // Fulfilled on the ready line OR on early exit, so a crashing helper
        // fails in seconds with its stderr instead of a 300 s silent timeout.
        let readyOrExited = expectation(description: "helper ready or exited")
        readyOrExited.assertForOverFulfill = false
        let portBox = PolishHelperPortBox()
        let stderrLog = PolishHelperLineLog()
        let reader = PipeLineReader(fileHandle: stderr.fileHandleForReading) { line in
            stderrLog.append(line)
            if let range = line.range(of: "ready on 127.0.0.1:"),
               let port = UInt16(line[range.upperBound...].prefix(while: \.isNumber))
            {
                if portBox.set(port) {
                    readyOrExited.fulfill()
                }
            }
        }
        process.terminationHandler = { _ in readyOrExited.fulfill() }

        try process.run()
        reader.start()
        addTeardownBlock {
            await Self.reapPolishHelper(process)
        }

        await fulfillment(of: [readyOrExited], timeout: PolishModelSnapshot.helperReadyTimeout)
        guard let port = portBox.get() else {
            let status = process.isRunning
                ? "still running, no ready line after \(Int(PolishModelSnapshot.helperReadyTimeout))s"
                : "exited with status \(process.terminationStatus)"
            XCTFail(
                """
                Helper failed to become ready (\(status)). stderr tail:
                \(stderrLog.tail(30))
                """
            )
            throw XCTSkip("helper did not become ready")
        }
        return (process, port, stderrLog)
    }

    /// Reap, don't just signal: SIGTERM is asynchronous, so `terminate()`
    /// alone lets the caller move on while the helper is still dying — in
    /// teardown that costs the CI runner ~105 s of orphan cleanup (#111),
    /// and between back-to-back launches it would briefly keep TWO copies
    /// of the model in memory on the shared runner. Wait for the exit
    /// (bounded), and escalate to SIGKILL if it never comes. Idempotent for
    /// an already-exited process.
    static func reapPolishHelper(_ process: Process) async {
        if process.isRunning {
            process.terminate()
        }
        let reaped = XCTestExpectation(description: "helper exited after SIGTERM")
        DispatchQueue.global().async {
            process.waitUntilExit()  // returns immediately if already exited
            reaped.fulfill()
        }
        _ = await XCTWaiter.fulfillment(of: [reaped], timeout: 10)
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
        }
    }
}

final class PolishHelperLineLog: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    func append(_ line: String) {
        lock.lock()
        lines.append(line)
        lock.unlock()
    }

    func tail(_ count: Int) -> String {
        lock.lock()
        defer { lock.unlock() }
        return lines.suffix(count).joined(separator: "\n")
    }

    func countOfLines(containing substring: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return lines.count { $0.contains(substring) }
    }
}

final class PolishHelperPortBox: @unchecked Sendable {
    private let lock = NSLock()
    private var port: UInt16?

    func set(_ value: UInt16) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard port == nil else { return false }
        port = value
        return true
    }

    func get() -> UInt16? {
        lock.lock()
        defer { lock.unlock() }
        return port
    }
}
