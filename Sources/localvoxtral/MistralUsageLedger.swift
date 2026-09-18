import Foundation
import Synchronization
import os

/// One billable request to Mistral's hosted API, as this Mac saw it. Never
/// holds dictated text: the ledger is counts, a model id and a price.
struct MistralUsageEntry: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        /// One realtime transcription socket (`voxtral-mini-transcribe-realtime-*`).
        case dictation
        /// One `/v1/chat/completions` polish request.
        case polish
    }

    let date: Date
    let kind: Kind
    let model: String
    /// Dictation: the seconds of audio this Mac put on the wire. Mistral's own
    /// `usage.prompt_audio_seconds` cannot stand in for it: measured
    /// 2026-09-18, it read 2 for clips of 4.6 s, 6.6 s and 30.7 s alike.
    var audioSeconds: Double?
    var promptTokens: Int?
    var cachedPromptTokens: Int?
    var completionTokens: Int?
    /// The estimate at the prices in force when the request was made, so a
    /// later price change never rewrites history. Nil when the model has no
    /// price here, or when the request may have been billed but reported no
    /// usage (a polish that timed out client-side).
    var costEUR: Double?
}

/// Mistral's list prices, in EUR, from docs.mistral.ai (checked 2026-09-18).
/// The API exposes no prices (`/v1/models` has none; the billing endpoint needs
/// an organization admin key), so these are pinned here and a model missing
/// from the table is logged with its counts and no cost.
enum MistralPricing {
    struct Price: Equatable, Sendable {
        var inputPerMillionTokens: Double = 0
        /// Cached prompt tokens bill at 10% of input unless the model says
        /// otherwise (docs: prompt caching → track billing).
        var cachedInputPerMillionTokens: Double?
        var outputPerMillionTokens: Double = 0
        var perAudioMinute: Double = 0
    }

    /// Keyed by every id `GET /v1/models` lists for the model, aliases
    /// included: a chat response echoes the id that was asked for, not the
    /// group's canonical name.
    private static let table: [String: Price] = {
        var table: [String: Price] = [:]
        func add(_ ids: [String], _ price: Price) {
            for id in ids { table[id] = price }
        }
        add(
            [
                "voxtral-mini-transcribe-realtime-2602", "voxtral-mini-realtime-2602",
                "voxtral-mini-realtime-latest",
            ],
            Price(perAudioMinute: 0.0053)
        )
        add(
            [
                "mistral-medium-latest", "mistral-medium", "mistral-medium-3-5",
                "mistral-medium-3.5", "mistral-medium-3", "mistral-medium-2604",
                "magistral-medium-latest",
            ],
            Price(inputPerMillionTokens: 1.25, outputPerMillionTokens: 6.4)
        )
        add(
            ["mistral-small-2603", "mistral-small-latest", "magistral-small-latest"],
            Price(inputPerMillionTokens: 0.12, outputPerMillionTokens: 0.5)
        )
        add(
            ["mistral-large-2512", "mistral-large-latest"],
            Price(inputPerMillionTokens: 0.44, outputPerMillionTokens: 1.3)
        )
        add(
            ["ministral-3b-2512", "ministral-3b-latest"],
            Price(inputPerMillionTokens: 0.088, outputPerMillionTokens: 0.088)
        )
        add(
            ["ministral-8b-2512", "ministral-8b-latest"],
            Price(inputPerMillionTokens: 0.13, outputPerMillionTokens: 0.13)
        )
        add(
            ["ministral-14b-2512", "ministral-14b-latest"],
            Price(inputPerMillionTokens: 0.18, outputPerMillionTokens: 0.18)
        )
        add(
            ["codestral-2508", "codestral-latest"],
            Price(inputPerMillionTokens: 0.26, outputPerMillionTokens: 0.79)
        )
        // GLM 5.3's page gives USD only (1.4 / 0.14 cached / 4.4), the same
        // as GLM 5.2, whose page converts that to these EUR figures.
        add(
            ["zai-glm-5-3", "zai-glm-5", "zai-glm-latest", "glm-5-2", "zai-glm-5-2"],
            Price(
                inputPerMillionTokens: 1.19,
                cachedInputPerMillionTokens: 0.119,
                outputPerMillionTokens: 3.74
            )
        )
        return table
    }()

    static func price(for model: String) -> Price? {
        table[model.trimmed.lowercased()]
    }

    static func dictationCost(model: String, audioSeconds: Double) -> Double? {
        guard let price = price(for: model), price.perAudioMinute > 0 else { return nil }
        return audioSeconds / 60 * price.perAudioMinute
    }

    static func polishCost(
        model: String,
        promptTokens: Int,
        cachedPromptTokens: Int,
        completionTokens: Int
    ) -> Double? {
        guard let price = price(for: model),
            price.inputPerMillionTokens > 0 || price.outputPerMillionTokens > 0
        else { return nil }
        let cached = min(max(cachedPromptTokens, 0), promptTokens)
        let cachedRate = price.cachedInputPerMillionTokens ?? price.inputPerMillionTokens / 10
        let total =
            Double(promptTokens - cached) * price.inputPerMillionTokens
            + Double(cached) * cachedRate
            + Double(completionTokens) * price.outputPerMillionTokens
        return total / 1_000_000
    }
}

/// Where Mistral requests report what they used. The realtime client and the
/// polishing service hold one of these; nothing else writes the ledger.
protocol MistralUsageRecording: Sendable {
    func record(_ entry: MistralUsageEntry)
}

/// The window Settings sums the ledger over.
enum MistralUsagePeriod: String, CaseIterable, Identifiable, Sendable {
    case today
    case sevenDays
    case thirtyDays
    case ninetyDays
    case allTime

    var id: String { rawValue }

    var label: String {
        switch self {
        case .today: return "Today"
        case .sevenDays: return "7 days"
        case .thirtyDays: return "30 days"
        case .ninetyDays: return "90 days"
        case .allTime: return "All time"
        }
    }

    /// The earliest date inside the window, nil for all time. "Today" starts
    /// at local midnight; the day counts are rolling and include today.
    func start(now: Date, calendar: Calendar = .current) -> Date? {
        let midnight = calendar.startOfDay(for: now)
        switch self {
        case .today: return midnight
        case .sevenDays: return calendar.date(byAdding: .day, value: -6, to: midnight)
        case .thirtyDays: return calendar.date(byAdding: .day, value: -29, to: midnight)
        case .ninetyDays: return calendar.date(byAdding: .day, value: -89, to: midnight)
        case .allTime: return nil
        }
    }
}

struct MistralUsageSummary: Equatable, Sendable {
    var costEUR: Double = 0
    var dictationCount = 0
    var audioSeconds: Double = 0
    var polishCount = 0
    /// Requests counted above whose cost is not in `costEUR`: a model with no
    /// price here, or a polish that timed out before Mistral said what it used.
    var unpricedCount = 0

    init() {}

    init(entries: [MistralUsageEntry], since start: Date?) {
        for entry in entries where start.map({ entry.date >= $0 }) ?? true {
            switch entry.kind {
            case .dictation:
                dictationCount += 1
                audioSeconds += entry.audioSeconds ?? 0
            case .polish:
                polishCount += 1
            }
            if let cost = entry.costEUR {
                costEUR += cost
            } else {
                unpricedCount += 1
            }
        }
    }

    var isEmpty: Bool { dictationCount == 0 && polishCount == 0 }

    /// The Usage row's one line, e.g. "€0.42 · 38 min dictated · 112 polishes".
    var line: String {
        guard !isEmpty else { return "No Mistral requests" }
        var parts = [Self.formattedCost(costEUR)]
        if dictationCount > 0 {
            parts.append("\(Self.formattedDuration(audioSeconds)) dictated")
        }
        if polishCount > 0 {
            parts.append(polishCount == 1 ? "1 polish" : "\(polishCount) polishes")
        }
        return parts.joined(separator: " · ")
    }

    /// Said only when something is missing from the total.
    var unpricedNote: String? {
        guard unpricedCount > 0 else { return nil }
        return unpricedCount == 1
            ? "1 request has no price and is not in the total"
            : "\(unpricedCount) requests have no price and are not in the total"
    }

    static func formattedCost(_ eur: Double) -> String {
        // Two decimals hide a month of light use; a cent's fraction is still
        // money on the bill when all you do is dictate.
        if eur > 0, eur < 0.01 { return "< €0.01" }
        return String(format: "€%.2f", eur)
    }

    static func formattedDuration(_ seconds: Double) -> String {
        let minutes = seconds / 60
        if minutes < 1 { return "\(Int(seconds.rounded())) s" }
        if minutes < 60 { return "\(Int(minutes.rounded())) min" }
        let hours = Int(minutes) / 60
        let rest = Int(minutes.rounded()) - hours * 60
        return rest == 0 ? "\(hours) h" : "\(hours) h \(rest) min"
    }
}

/// The local record of every Mistral request: an append-only JSON-lines file
/// under Application Support, one line per request. Kept in memory as well so
/// Settings can sum any window without touching the disk.
final class MistralUsageLedger: MistralUsageRecording, @unchecked Sendable {
    private struct State {
        var entries: [MistralUsageEntry]?
    }

    let fileURL: URL?
    private let state = Mutex(State())
    private let writeQueue = DispatchQueue(label: "localvoxtral.mistral-usage", qos: .utility)
    private let onChange: (@Sendable () -> Void)?

    /// `fileURL` nil keeps the ledger in memory only (tests, previews). The
    /// file is read on a background queue right away, so the first Settings
    /// render does not pay for it on the main thread.
    init(fileURL: URL?, onChange: (@Sendable () -> Void)? = nil) {
        self.fileURL = fileURL
        self.onChange = onChange
        if fileURL != nil {
            writeQueue.async { [self] in _ = entries() }
        }
    }

    static func defaultFileURL() -> URL {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        return applicationSupport
            .appendingPathComponent("localvoxtral", isDirectory: true)
            .appendingPathComponent("mistral-usage.jsonl")
    }

    func record(_ entry: MistralUsageEntry) {
        let line: Data?
        do {
            line = try Self.encoder.encode(entry) + Data("\n".utf8)
        } catch {
            Log.persistence.error(
                "mistral usage: encode failed: \(error.localizedDescription, privacy: .public)")
            line = nil
        }
        state.withLock { s in
            if s.entries == nil { s.entries = loadEntries() }
            s.entries?.append(entry)
        }
        Log.persistence.info(
            "mistral usage: \(entry.kind.rawValue, privacy: .public) model=\(entry.model, privacy: .public) audioSeconds=\(entry.audioSeconds ?? 0, privacy: .public) promptTokens=\(entry.promptTokens ?? -1, privacy: .public) completionTokens=\(entry.completionTokens ?? -1, privacy: .public) costEUR=\(entry.costEUR ?? -1, privacy: .public)"
        )
        // Synchronous: one short append, and a line still queued when the app
        // quits would be lost. Callers are socket and network threads, never
        // the main thread.
        if let fileURL, let line {
            writeQueue.sync {
                Self.append(line, to: fileURL)
            }
        }
        onChange?()
    }

    func entries() -> [MistralUsageEntry] {
        state.withLock { s in
            if s.entries == nil { s.entries = loadEntries() }
            return s.entries ?? []
        }
    }

    func summary(for period: MistralUsagePeriod, now: Date = Date()) -> MistralUsageSummary {
        MistralUsageSummary(entries: entries(), since: period.start(now: now))
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

    /// A line that does not decode (a torn write, a hand edit) is skipped, not
    /// fatal: losing one request's cost beats losing the ledger.
    static func entries(fromFileContents data: Data) -> [MistralUsageEntry] {
        data.split(separator: UInt8(ascii: "\n")).compactMap { line in
            try? decoder.decode(MistralUsageEntry.self, from: Data(line))
        }
    }

    private func loadEntries() -> [MistralUsageEntry] {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return [] }
        return Self.entries(fromFileContents: data)
    }

    private static func append(_ line: Data, to fileURL: URL) {
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !fileManager.fileExists(atPath: fileURL.path) {
                guard fileManager.createFile(atPath: fileURL.path, contents: line) else {
                    Log.persistence.error("mistral usage: could not create \(fileURL.path, privacy: .public)")
                    return
                }
                return
            }
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        } catch {
            Log.persistence.error(
                "mistral usage: append failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
