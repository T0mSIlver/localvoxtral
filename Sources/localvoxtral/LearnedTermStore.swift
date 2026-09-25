import Foundation
import Synchronization
import os

/// The file around `LearnedTerms`: one small JSON document under Application
/// Support, held in memory so that NOTHING on the dictation commit path or in
/// Settings ever touches the disk. Reads answer from memory or answer empty;
/// writes are folded in on the store's own queue. The file is loaded there
/// once at launch, so the only window where a reader sees an empty memory is
/// between launch and that first load.
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
    /// read on the write queue right away, and every later read and write is
    /// ordered behind that, so nothing else ever has to load it.
    init(
        fileURL: URL?,
        now: @escaping @Sendable () -> Date = { Date() },
        onChange: (@Sendable () -> Void)? = nil
    ) {
        self.fileURL = fileURL
        self.now = now
        self.onChange = onChange
        if fileURL != nil {
            writeQueue.async { [self] in
                let loaded = loadFromDisk()
                state.withLock { state in
                    if state.terms == nil { state.terms = loaded }
                }
            }
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

    /// What is in memory, without ever reading the disk: callers are the
    /// `@MainActor` commit path and Settings, and neither may block on a
    /// volume (review, 2026-09-20). Before the launch load lands this answers
    /// empty, which costs the first dictation its remembered terms and nothing
    /// else.
    func snapshot() -> LearnedTerms {
        state.withLock { $0.terms } ?? LearnedTerms()
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
    /// One dictation's resolved terms.
    ///
    /// The whole fold happens on the write queue, behind the launch load and
    /// behind any earlier record: the commit path hands over the observations
    /// and returns. That is what keeps a dictation off the disk, and it is
    /// also what makes the file's order the memory's order — two records can
    /// no longer hand the queue an older state after a newer one.
    func record(
        _ observations: [LearnedTermObservation],
        project: LearnedTermProjectResolver.Identity
    ) {
        guard !observations.isEmpty else { return }
        let moment = now()
        writeQueue.async { [self] in
            // Outside the lock: a reader on the main actor must never wait
            // behind a disk read, even one that has already happened.
            let fallback = state.withLock { $0.terms } ?? loadFromDisk()
            let updated: LearnedTerms = state.withLock { state in
                var terms = state.terms ?? fallback
                terms.record(observations, project: project, now: moment)
                state.terms = terms
                return terms
            }
            Log.polishing.info(
                "Learned terms recorded: \(observations.count, privacy: .public) in project \(project.key == LearnedTermProjectResolver.shared.key ? "shared" : "keyed", privacy: .public), \(updated.termCount, privacy: .public) kept"
            )
            write(updated)
            onChange?()
        }
    }

    /// A spelling the user fixed a dictation to by hand, confirmed at once
    /// (`LearnedTerms.recordCorrection`). Ordered on the write queue like
    /// `record`.
    func recordCorrection(_ term: String, project: LearnedTermProjectResolver.Identity) {
        let moment = now()
        mutate { terms in
            terms.recordCorrection(term, project: project, now: moment)
        }
        Log.polishing.info(
            "Learned terms: correction recorded in project \(project.key == LearnedTermProjectResolver.shared.key ? "shared" : "keyed", privacy: .public)"
        )
    }

    /// Drops one spelling from one project: Undo, or the user reverting it.
    func forget(_ term: String, projectKey: String) {
        mutate { terms in
            terms.forget(term, projectKey: projectKey)
        }
        Log.polishing.info("Learned terms: one term forgotten")
    }

    /// Settings' pin: keeps one spelling past decay and caps.
    func setPinned(_ pinned: Bool, term: String, projectKey: String) {
        mutate { terms in
            terms.setPinned(pinned, term: term, projectKey: projectKey)
        }
        Log.polishing.info("Learned terms: one term \(pinned ? "pinned" : "unpinned", privacy: .public)")
    }

    /// Folds `change` in on the write queue, behind the launch load and every
    /// earlier write, so an Undo can never land before the term it undoes.
    private func mutate(_ change: @escaping @Sendable (inout LearnedTerms) -> Void) {
        writeQueue.async { [self] in
            let fallback = state.withLock { $0.terms } ?? loadFromDisk()
            let updated: LearnedTerms = state.withLock { state in
                var terms = state.terms ?? fallback
                change(&terms)
                state.terms = terms
                return terms
            }
            write(updated)
            onChange?()
        }
    }

    /// The Forget button. Drops the file as well as the memory: a user who
    /// asks to forget should not find the terms back after a relaunch.
    ///
    /// Memory clears at once so the row reads zero under the click; the file is
    /// removed on the queue, ordered behind any record already in flight, so a
    /// dictation that was mid-fold cannot re-create the file afterwards.
    func forgetAll() {
        state.withLock { state in state.terms = LearnedTerms() }
        Log.polishing.info("Learned terms forgotten")
        writeQueue.async { [self] in
            state.withLock { state in state.terms = LearnedTerms() }
            if let fileURL {
                try? FileManager.default.removeItem(at: fileURL)
            }
            onChange?()
        }
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

    private func loadFromDisk() -> LearnedTerms {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return LearnedTerms() }
        var terms = Self.terms(fromFileContents: data)
        // Decay applies to a file that has been sitting still, not only to one
        // being written: a project left alone for a season must not come back
        // grounding today's dictation.
        terms.prune(now: now())
        return terms
    }

    /// Called on the write queue, never off it.
    private func write(_ terms: LearnedTerms) {
        guard let fileURL else { return }
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
