import Foundation
import os

/// One Overlay Buffer dictation's early polish (#709): while the user speaks,
/// each settled piece (`EarlyPolishPlan`) is polished on its own, one at a
/// time, so the stop only has the tail left.
///
/// A piece request carries only what every polish carries: the profile's
/// templates, the reference guide and About you. The stop reuses the pieces
/// only when its own request for the whole text would carry nothing more
/// (`StopCommitCoordinator.polish`); anything the stop sample grounds the
/// polish in means the whole text is polished as before.
///
/// The bundled helper has one generation slot and keeps generating after its
/// client drops a request, so a piece is never cancelled to make room: the
/// stop waits for the one in flight and keeps it.
@MainActor
final class EarlyPolishRun {
    struct Piece {
        let input: String
        let output: String
    }

    /// What the stop gets: the pieces, the exact prefix of the settled text
    /// they cover, and what they were polished with.
    struct Handoff {
        let pieces: [Piece]
        let consumedPrefix: String
        let templates: LLMPromptTemplates
        let configuration: LLMPolishingConfiguration
        /// How long the stop waited for the piece in flight.
        let waitSeconds: Double
    }

    private let service: any LLMPolishingServicing
    private let configuration: LLMPolishingConfiguration
    private let templates: @MainActor () -> LLMPromptTemplates
    private let now: @Sendable () -> Date
    private var resolvedTemplates: LLMPromptTemplates?
    private var pieces: [Piece] = []
    private var consumedPrefix = ""
    private var inFlight: Task<Void, Never>?
    private var latestSettledText = ""
    /// No new piece starts: the user stopped, a piece failed, or the session
    /// ended.
    private var closed = false

    /// `templates` is read when the first piece is sent, once the session's
    /// target and join are known; the stop compares it with its own.
    init(
        service: any LLMPolishingServicing,
        configuration: LLMPolishingConfiguration,
        templates: @escaping @MainActor () -> LLMPromptTemplates,
        now: @escaping @Sendable () -> Date
    ) {
        self.service = service
        self.configuration = configuration
        self.templates = templates
        self.now = now
    }

    /// The dictation's settled text changed (a backend final landed).
    func settledTextChanged(_ settledText: String) {
        latestSettledText = settledText
        startNextPieceIfIdle()
    }

    private func startNextPieceIfIdle() {
        guard !closed, inFlight == nil,
            let next = EarlyPolishPlan.nextPiece(
                settledText: latestSettledText, consumedPrefix: consumedPrefix)
        else { return }
        let templates = resolvedTemplates ?? templates()
        resolvedTemplates = templates
        let request = PolishRequestAssembler.bareRequest(workingText: next.piece, templates: templates)
        let index = pieces.count
        let wordCount = next.piece.split(whereSeparator: \.isWhitespace).count
        Log.polishing.info(
            "early polish: piece \(index, privacy: .public) sent (\(wordCount, privacy: .public) words)"
        )
        let service = service
        let configuration = configuration
        inFlight = Task { @MainActor [weak self] in
            do {
                let result = try await service.polish(request: request, configuration: configuration)
                Log.polishing.info(
                    "early polish: piece \(index, privacy: .public) answered in \(result.durationSeconds, format: .fixed(precision: 2), privacy: .public) s"
                )
                self?.pieceFinished(input: next.piece, output: result.polishedText, consumedPrefix: next.consumedPrefix)
            } catch {
                Log.polishing.error(
                    "early polish: piece \(index, privacy: .public) failed, the stop polishes the rest: \(error.localizedDescription, privacy: .public)"
                )
                self?.pieceFailed()
            }
        }
    }

    private func pieceFinished(input: String, output: String, consumedPrefix: String) {
        inFlight = nil
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            Log.polishing.error("early polish: a piece came back empty; the stop polishes the rest")
            closed = true
            return
        }
        pieces.append(Piece(input: input, output: trimmed))
        self.consumedPrefix = consumedPrefix
        startNextPieceIfIdle()
    }

    private func pieceFailed() {
        inFlight = nil
        closed = true
    }

    /// Called at stop: no new piece starts. Waits for the piece in flight, so
    /// the stop's own request does not queue behind it on the helper's one
    /// slot for nothing. Nil when no piece finished. A cancelled caller stops
    /// waiting and gets nil.
    func finish() async -> Handoff? {
        closed = true
        let started = now()
        if let inFlight {
            await withTaskCancellationHandler {
                await inFlight.value
            } onCancel: {
                inFlight.cancel()
            }
        }
        guard !Task.isCancelled, !pieces.isEmpty, let resolvedTemplates else { return nil }
        return Handoff(
            pieces: pieces,
            consumedPrefix: consumedPrefix,
            templates: resolvedTemplates,
            configuration: configuration,
            waitSeconds: max(0, now().timeIntervalSince(started))
        )
    }

    /// The user stopped: no new piece starts. The one in flight runs on.
    func close() {
        closed = true
    }

    /// The session ended without a commit that uses the pieces.
    func cancel() {
        closed = true
        inFlight?.cancel()
        inFlight = nil
    }
}
