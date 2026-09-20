import Foundation
import Synchronization
import os

/// The file around `LearnedTerms`: one small JSON document under Application
/// Support, held in memory so a commit never waits on a disk read and Settings
/// never counts terms on the main thread.
///
/// Never holds dictated text. A remembered term is a spelling the polish
/// pipeline already resolved — a file name, a product, a model — and the
/// counters beside it, which is exactly what `SpeakerTerms` keeps for the
/// hand-written list.
final class LearnedTermStore: @unchecked Sendable {
    private struct State {
        var terms: LearnedTerms?
    }

    let fileURL: URL?
    private let state = Mutex(State())
    private let writeQueue = DispatchQueue(label: "localvoxtral.learned-terms", qos: .utility)
    private let now: @Sendable () -> Date
    private let onChange: (@Sendable () -> Void)?

    /// `fileURL` nil keeps everything in memory (tests, previews). The file is
    /// read on the background queue right away so the first dictation and the
    /// first Settings render both find it loaded.
    init(
        fileURL: URL?,
        now: @escaping @Sendable () -> Date = { Date() },
        onChange: (@Sendable () -> Void)? = nil
    ) {
        self.fileURL = fileURL
        self.now = now
        self.onChange = onChange
        if fileURL != nil {
            writeQueue.async { [self] in _ = snapshot() }
        }
    }

    static func defaultFileURL() -> URL {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        return applicationSupport
            .appendingPathComponent("localvoxtral", isDirectory: true)
            .appendingPathComponent("learned-terms.json")
    }

    // MARK: Reading

    /// The lock is never held across the file read: a first caller that has to
    /// load must not park every other thread on a disk it might be waiting for
    /// (review, 2026-09-20). Two threads racing the first load both read; the
    /// first to finish wins and the other discards its copy, which costs one
    /// redundant read at most once per launch.
    func snapshot() -> LearnedTerms {
        if let cached = state.withLock({ $0.terms }) { return cached }
        let loaded = load()
        return state.withLock { state in
            if let cached = state.terms { return cached }
            state.terms = loaded
            return loaded
        }
    }

    /// The confirmed spellings for one project, strongest evidence first.
    func confirmedTerms(
        projectKey: String,
        minimumDictations: Int = LearnedTerms.confirmedDictations
    ) -> [String] {
        snapshot().confirmedTerms(projectKey: projectKey, minimumDictations: minimumDictations)
    }

    /// Terms, then projects — what the Settings row states.
    func summary() -> (terms: Int, projects: Int) {
        let terms = snapshot()
        return (terms.termCount, terms.projects.count)
    }

    // MARK: Writing

    /// One dictation's resolved terms. Returns without touching the disk when
    /// there is nothing to remember, which is the common case for a sentence
    /// the recognizer got right.
    func record(_ observations: [LearnedTermObservation], project: LearnedTermProjectResolver.Identity) {
        guard !observations.isEmpty else { return }
        let moment = now()
        let loaded = snapshot()
        let updated: LearnedTerms = state.withLock { state in
            var terms = state.terms ?? loaded
            terms.record(observations, project: project, now: moment)
            state.terms = terms
            // Enqueued INSIDE the lock so the queue receives the snapshots in
            // the order they were produced. Enqueuing after the release lets
            // two records hand the serial queue an older state after a newer
            // one and leave the file behind the memory (review, 2026-09-20).
            // Safe: nothing on the write queue takes this lock.
            persist(terms)
            return terms
        }
        Log.polishing.info(
            "Learned terms recorded: \(observations.count, privacy: .public) in project \(project.key == LearnedTermProjectResolver.shared.key ? "shared" : "keyed", privacy: .public), \(updated.termCount, privacy: .public) kept"
        )
        onChange?()
    }

    /// The Forget button. Drops the file as well as the memory: a user who
    /// asks to forget should not find the terms back after a relaunch.
    func forgetAll() {
        state.withLock { state in state.terms = LearnedTerms() }
        if let fileURL {
            writeQueue.async {
                try? FileManager.default.removeItem(at: fileURL)
            }
        }
        Log.polishing.info("Learned terms forgotten")
        onChange?()
    }

    /// Blocks until the queued writes have landed. For tests and for nothing
    /// else — the app never waits on this queue.
    func waitForPendingWrites() {
        writeQueue.sync {}
    }

    // MARK: File

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    /// A file that does not decode — a torn write, a hand edit, a version this
    /// build predates — starts over empty. Losing what was learned costs a few
    /// dictations; refusing to start costs the feature.
    static func terms(fromFileContents data: Data) -> LearnedTerms {
        guard let terms = try? decoder.decode(LearnedTerms.self, from: data),
              terms.version <= LearnedTerms.currentVersion
        else { return LearnedTerms() }
        return terms
    }

    private func load() -> LearnedTerms {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return LearnedTerms() }
        var terms = Self.terms(fromFileContents: data)
        // Decay applies to a file that has been sitting still, not only to one
        // being written: a project left alone for a season must not come back
        // grounding today's dictation.
        terms.prune(now: now())
        return terms
    }

    /// Asynchronous on purpose: `record` is called from the commit path on the
    /// main actor, and a dictation must never wait on a write. One dictation's
    /// terms lost to a crash between the two is a re-learn, not a defect.
    private func persist(_ terms: LearnedTerms) {
        guard let fileURL else { return }
        writeQueue.async {
            do {
                let data = try Self.encoder.encode(terms)
                try FileManager.default.createDirectory(
                    at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
                )
                try data.write(to: fileURL, options: .atomic)
            } catch {
                Log.persistence.error(
                    "learned terms: write failed: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }
}
