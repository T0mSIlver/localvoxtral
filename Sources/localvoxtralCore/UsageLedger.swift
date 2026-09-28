import Foundation
import Synchronization
#if canImport(os)
import os
#endif

/// One request a feature sent to a model, as this Mac saw it: which feature
/// asked, which backend answered (and so who pays), and what it used. Never
/// holds dictated text, prompts, terms or project names: the ledger is
/// counts, a model id and a price.
package struct UsageEntry: Codable, Equatable, Sendable {
    /// What asked. One per feature the owner wants to see the cost of (#837).
    package enum Feature: String, Codable, CaseIterable, Sendable {
        /// One realtime transcription socket.
        case dictation
        /// One polish of a dictation.
        case polish
        /// The Mistral batch transcription an Overlay Buffer dictation gets on
        /// stop (#317). Its audio was already counted by the realtime socket.
        case secondPass
        /// "Suggest terms", from the button or every N dictations.
        case termSuggestions
        /// A joined agent's run listing a new project's terms (#609, #641).
        case projectTerms
        /// Picking a quick capture's project: Jev, or the chat fallback.
        case quickCaptureRouting
        /// An agent's run drafting a quick capture as an issue (#731, #745).
        case quickCaptureDrafting
        /// The one polish a quick capture gets before routing (#970).
        case quickCapturePolish
    }

    /// What answered, which says who pays: the Mistral key, the Jev key, the
    /// user's own machine or server (nobody), or an agent's own plan.
    package enum Backend: String, Codable, CaseIterable, Sendable {
        case mistral
        case jev
        /// The bundled helper (polishd, speechd).
        case bundledHelper
        /// A server the user configured by URL.
        case userServer
        case claudeCode
        case codex
        case opencode
        case vibe

        /// Runs on a plan or key the app never sees the bill of.
        package var isAgent: Bool {
            switch self {
            case .claudeCode, .codex, .opencode, .vibe: return true
            case .mistral, .jev, .bundledHelper, .userServer: return false
            }
        }
    }

    /// The ledger's first format, written before `feature` and `backend`
    /// existed: every line was a Mistral request of one of these kinds.
    package enum Kind: String, Codable, Sendable {
        case dictation
        case polish
        case retranscription
    }

    package let date: Date
    package let feature: Feature
    package let backend: Backend
    package let model: String
    /// Dictation: the seconds of audio this Mac put on the wire. Mistral's own
    /// `usage.prompt_audio_seconds` cannot stand in for it: measured
    /// 2026-09-18, it read 2 for clips of 4.6 s, 6.6 s and 30.7 s alike.
    package var audioSeconds: Double?
    /// Every prompt token, cached ones included. For an agent run, the sum of
    /// its uncached input, cache writes and cache reads over all its turns.
    package var promptTokens: Int?
    package var cachedPromptTokens: Int?
    package var completionTokens: Int?
    /// The estimate at the prices in force when the request was made, so a
    /// later price change never rewrites history. Nil when the model has no
    /// price here, when the request may have been billed but reported no
    /// usage (a polish that timed out client-side), or when the backend is
    /// not Mistral.
    package var costEUR: Double?
    /// What an agent run reported it would cost at API prices. On a
    /// subscription it comes out of the plan's limits, not a bill.
    package var agentCostUSD: Double?
    /// A call priced here in USD from its token counts: Jev, at its list
    /// price when the answer reports them.
    package var costUSD: Double?

    package init(
        date: Date,
        feature: Feature,
        backend: Backend,
        model: String,
        audioSeconds: Double? = nil,
        promptTokens: Int? = nil,
        cachedPromptTokens: Int? = nil,
        completionTokens: Int? = nil,
        costEUR: Double? = nil,
        agentCostUSD: Double? = nil,
        costUSD: Double? = nil
    ) {
        self.date = date
        self.feature = feature
        self.backend = backend
        self.model = model
        self.audioSeconds = audioSeconds
        self.promptTokens = promptTokens
        self.cachedPromptTokens = cachedPromptTokens
        self.completionTokens = completionTokens
        self.costEUR = costEUR
        self.agentCostUSD = agentCostUSD
        self.costUSD = costUSD
    }

    /// A Mistral request in the ledger's first terms.
    package init(
        date: Date,
        kind: Kind,
        model: String,
        audioSeconds: Double? = nil,
        promptTokens: Int? = nil,
        cachedPromptTokens: Int? = nil,
        completionTokens: Int? = nil,
        costEUR: Double? = nil
    ) {
        self.init(
            date: date,
            feature: Self.feature(of: kind),
            backend: .mistral,
            model: model,
            audioSeconds: audioSeconds,
            promptTokens: promptTokens,
            cachedPromptTokens: cachedPromptTokens,
            completionTokens: completionTokens,
            costEUR: costEUR
        )
    }

    private static func feature(of kind: Kind) -> Feature {
        switch kind {
        case .dictation: return .dictation
        case .polish: return .polish
        case .retranscription: return .secondPass
        }
    }

    /// What a build that knows only `kind` makes of this line. Mistral chat
    /// requests other than polishes were recorded as polishes before #837, so
    /// such a build keeps summing them the way it always did; a line it would
    /// misread (a free local call, an agent run) carries no kind and is
    /// skipped there.
    package var legacyKind: Kind? {
        guard backend == .mistral else { return nil }
        switch feature {
        case .dictation: return .dictation
        case .secondPass: return .retranscription
        case .polish, .termSuggestions, .quickCaptureRouting, .quickCapturePolish: return .polish
        case .projectTerms, .quickCaptureDrafting: return nil
        }
    }

    private enum CodingKeys: String, CodingKey {
        case date, feature, backend, kind, model, audioSeconds, promptTokens,
            cachedPromptTokens, completionTokens, costEUR, agentCostUSD, costUSD
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        date = try container.decode(Date.self, forKey: .date)
        if let feature = try container.decodeIfPresent(Feature.self, forKey: .feature) {
            self.feature = feature
        } else {
            feature = Self.feature(of: try container.decode(Kind.self, forKey: .kind))
        }
        backend = try container.decodeIfPresent(Backend.self, forKey: .backend) ?? .mistral
        model = try container.decode(String.self, forKey: .model)
        audioSeconds = try container.decodeIfPresent(Double.self, forKey: .audioSeconds)
        promptTokens = try container.decodeIfPresent(Int.self, forKey: .promptTokens)
        cachedPromptTokens = try container.decodeIfPresent(Int.self, forKey: .cachedPromptTokens)
        completionTokens = try container.decodeIfPresent(Int.self, forKey: .completionTokens)
        costEUR = try container.decodeIfPresent(Double.self, forKey: .costEUR)
        agentCostUSD = try container.decodeIfPresent(Double.self, forKey: .agentCostUSD)
        costUSD = try container.decodeIfPresent(Double.self, forKey: .costUSD)
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(date, forKey: .date)
        try container.encode(feature, forKey: .feature)
        try container.encode(backend, forKey: .backend)
        try container.encodeIfPresent(legacyKind, forKey: .kind)
        try container.encode(model, forKey: .model)
        try container.encodeIfPresent(audioSeconds, forKey: .audioSeconds)
        try container.encodeIfPresent(promptTokens, forKey: .promptTokens)
        try container.encodeIfPresent(cachedPromptTokens, forKey: .cachedPromptTokens)
        try container.encodeIfPresent(completionTokens, forKey: .completionTokens)
        try container.encodeIfPresent(costEUR, forKey: .costEUR)
        try container.encodeIfPresent(agentCostUSD, forKey: .agentCostUSD)
        try container.encodeIfPresent(costUSD, forKey: .costUSD)
    }
}

extension UsageEntry {
    /// One chat/completions request. Mistral prices it by the answering model
    /// when the price table knows it, the requested model otherwise (an alias
    /// that starts answering with a newer id keeps its price); a request with
    /// no usage is counted, unpriced. Any other backend is counted, never
    /// priced.
    package static func chat(
        date: Date,
        feature: Feature,
        backend: Backend,
        requestedModel: String,
        usage: LLMTokenUsage?
    ) -> Self {
        let requested = requestedModel.trimmed
        var entry = UsageEntry(
            date: date, feature: feature, backend: backend, model: usage?.model ?? requested)
        guard let usage else { return entry }
        entry.promptTokens = usage.promptTokens
        entry.cachedPromptTokens = usage.cachedPromptTokens
        entry.completionTokens = usage.completionTokens
        guard backend == .mistral else { return entry }
        let cost = { (id: String) in
            MistralPricing.polishCost(
                model: id,
                promptTokens: usage.promptTokens,
                cachedPromptTokens: usage.cachedPromptTokens,
                completionTokens: usage.completionTokens
            )
        }
        entry.costEUR = cost(entry.model) ?? cost(requested)
        return entry
    }

    /// One headless agent run. `model` is what the app asked for ("sonnet"),
    /// or "default" when the run takes the user's own. A run that reported
    /// nothing (Vibe, a remote host) is still counted.
    package static func agentRun(
        date: Date,
        feature: Feature,
        backend: Backend,
        model: String,
        usage: ProjectTermProposal.Usage?
    ) -> Self {
        var entry = UsageEntry(date: date, feature: feature, backend: backend, model: model)
        guard let usage else { return entry }
        let prompt = [usage.inputTokens, usage.cacheWriteTokens, usage.cacheReadTokens].compactMap { $0 }
        entry.promptTokens = prompt.isEmpty ? nil : prompt.reduce(0, +)
        entry.cachedPromptTokens = usage.cacheReadTokens
        entry.completionTokens = usage.outputTokens
        entry.agentCostUSD = usage.costUSD
        return entry
    }
}

extension UsageEntry {
    /// One of our own headless runs of `agent`: the model the app asks for,
    /// or "default" when the run takes the user's own.
    package static func agentRun(
        date: Date,
        feature: Feature,
        agent: ProjectTermProposal.Agent,
        usage: ProjectTermProposal.Usage?
    ) -> Self {
        agentRun(
            date: date,
            feature: feature,
            backend: Backend(agent),
            model: agent == .claude ? "sonnet" : "default",
            usage: usage
        )
    }
}

extension QuickCaptureDraft {
    /// Counts a drafting run that started, local or on a host, with the
    /// usage it reported.
    package static func recordUsage(
        of outcome: Outcome,
        agent: ProjectTermProposal.Agent,
        date: Date,
        to recorder: (any UsageRecording)?
    ) {
        guard let recorder else { return }
        switch outcome {
        case .draft(_, let usage):
            recorder.record(.agentRun(date: date, feature: .quickCaptureDrafting, agent: agent, usage: usage))
        case .failed(let failure) where failure.agentRan:
            recorder.record(.agentRun(date: date, feature: .quickCaptureDrafting, agent: agent, usage: nil))
        case .failed, .notRun:
            break
        }
    }
}

extension ProjectTermProposal.Failure {
    /// The agent started, so the run may have spent: every failure but a
    /// binary that is missing or would not launch.
    package var agentRan: Bool {
        switch self {
        case .agentNotFound, .launchFailed: return false
        case .timedOut, .outputTooLarge, .exit, .budgetExceeded, .turnLimit, .agentError,
            .malformedOutput:
            return true
        }
    }
}

extension UsageEntry.Backend {
    /// The backend an agent run bills.
    package init(_ agent: ProjectTermProposal.Agent) {
        switch agent {
        case .claude: self = .claudeCode
        case .vibe: self = .vibe
        case .opencode: self = .opencode
        }
    }
}

/// A chat/completions response's `usage` object, plus the model that answered.
package struct LLMTokenUsage: Equatable, Sendable {
    package let model: String?
    package let promptTokens: Int
    package let cachedPromptTokens: Int
    package let completionTokens: Int

    package init(model: String?, promptTokens: Int, cachedPromptTokens: Int = 0, completionTokens: Int) {
        self.model = model
        self.promptTokens = promptTokens
        self.cachedPromptTokens = cachedPromptTokens
        self.completionTokens = completionTokens
    }

    /// Nil when the response carries no `usage` with at least the prompt and
    /// completion counts.
    package init?(responseObject json: [String: Any]) {
        guard let usage = json["usage"] as? [String: Any],
            let prompt = (usage["prompt_tokens"] as? NSNumber)?.intValue,
            let completion = (usage["completion_tokens"] as? NSNumber)?.intValue
        else { return nil }
        let details = usage["prompt_tokens_details"] as? [String: Any]
        self.init(
            model: (json["model"] as? String).flatMap { $0.trimmed.isEmpty ? nil : $0.trimmed },
            promptTokens: prompt,
            cachedPromptTokens: (details?["cached_tokens"] as? NSNumber)?.intValue ?? 0,
            completionTokens: completion
        )
    }
}

/// Mistral's list prices, in EUR, from docs.mistral.ai (checked 2026-09-18).
/// The API exposes no prices (`/v1/models` has none; the billing endpoint needs
/// an organization admin key), so these are pinned here and a model missing
/// from the table is logged with its counts and no cost.
package enum MistralPricing {
    package struct Price: Equatable, Sendable {
        package var inputPerMillionTokens: Double = 0
        /// Cached prompt tokens bill at 10% of input unless the model says
        /// otherwise (docs: prompt caching → track billing).
        package var cachedInputPerMillionTokens: Double?
        package var outputPerMillionTokens: Double = 0
        package var perAudioMinute: Double = 0
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
        // Voxtral Mini Transcribe 2, the batch model: 0.003 USD/min
        // (docs: models/voxtral-mini-transcribe-26-02, checked 2026-09-26).
        add(["voxtral-mini-latest", "voxtral-mini-2602"], Price(perAudioMinute: 0.0026))
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

    package static func price(for model: String) -> Price? {
        table[model.trimmed.lowercased()]
    }

    package static func dictationCost(model: String, audioSeconds: Double) -> Double? {
        guard let price = price(for: model), price.perAudioMinute > 0 else { return nil }
        return audioSeconds / 60 * price.perAudioMinute
    }

    package static func polishCost(
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

/// Where requests report what they used. Everything that calls a model holds
/// one of these; nothing else writes the ledger.
package protocol UsageRecording: Sendable {
    func record(_ entry: UsageEntry)
}

/// The window the Mistral Usage row sums the ledger over.
package enum MistralUsagePeriod: String, CaseIterable, Identifiable, Sendable {
    case today
    case sevenDays
    case thirtyDays
    case ninetyDays
    case allTime

    package var id: String { rawValue }

    package var label: String {
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
    package func start(now: Date, calendar: Calendar = .current) -> Date? {
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

/// The Mistral key's share of the ledger: every feature's Mistral requests
/// in the cost, with dictations, polishes and second passes counted.
package struct MistralUsageSummary: Equatable, Sendable {
    package var costEUR: Double = 0
    package var dictationCount = 0
    package var audioSeconds: Double = 0
    package var polishCount = 0
    package var retranscriptionCount = 0
    /// Mistral requests of the other features: term suggestions, the
    /// quick-capture chat fallback.
    package var otherCount = 0
    /// Requests counted above whose cost is not in `costEUR`: a model with no
    /// price here, or a polish that timed out before Mistral said what it used.
    package var unpricedCount = 0

    package init() {}

    package init(entries: [UsageEntry], since start: Date?) {
        for entry in entries
        where entry.backend == .mistral && (start.map({ entry.date >= $0 }) ?? true) {
            switch entry.feature {
            case .dictation:
                dictationCount += 1
                audioSeconds += entry.audioSeconds ?? 0
            case .polish:
                polishCount += 1
            case .secondPass:
                retranscriptionCount += 1
            case .termSuggestions, .projectTerms, .quickCaptureRouting, .quickCaptureDrafting, .quickCapturePolish:
                otherCount += 1
            }
            if let cost = entry.costEUR {
                costEUR += cost
            } else {
                unpricedCount += 1
            }
        }
    }

    package var isEmpty: Bool {
        dictationCount == 0 && polishCount == 0 && retranscriptionCount == 0 && otherCount == 0
    }

    /// The Usage row's one line, e.g. "€0.42 · 38 min dictated · 112 polishes".
    /// Requests with no price say so beside the total: "€0.42 + 2 unpriced".
    package var line: String {
        guard !isEmpty else { return "No Mistral requests" }
        var cost = Self.formattedCost(costEUR)
        if unpricedCount > 0 {
            cost += " + \(unpricedCount) unpriced"
        }
        var parts = [cost]
        if dictationCount > 0 {
            parts.append("\(Self.formattedDuration(audioSeconds)) dictated")
        }
        if polishCount > 0 {
            parts.append(polishCount == 1 ? "1 polish" : "\(polishCount) polishes")
        }
        return parts.joined(separator: " · ")
    }

    package static func formattedCost(_ eur: Double) -> String {
        WidgetFormat.cost(eur)
    }

    package static func formattedDuration(_ seconds: Double) -> String {
        WidgetFormat.duration(seconds)
    }
}

/// One feature's use over a window, for every backend it reached.
package struct FeatureUsage: Equatable, Sendable {
    /// What one backend took of a feature's calls, and what it cost.
    package struct Share: Equatable, Sendable {
        package var calls = 0
        package var costEUR: Double = 0
        package var agentCostUSD: Double = 0
        package var costUSD: Double = 0
        /// Calls on a paid backend that carry no price.
        package var unpricedCalls = 0

        package init() {}
    }

    package let feature: UsageEntry.Feature
    package var calls = 0
    package var promptTokens = 0
    package var completionTokens = 0
    package var audioSeconds: Double = 0
    /// Mistral spend, priced at request time.
    package var costEUR: Double = 0
    /// What agent runs reported at API prices.
    package var agentCostUSD: Double = 0
    /// USD priced here from token counts (Jev).
    package var costUSD: Double = 0
    /// Calls that reached a paid backend and carry no price: a Mistral model
    /// missing from the table, a timed-out request, a Jev answer with no
    /// token counts, an agent run that reported nothing.
    package var unpricedPaidCalls = 0
    /// Per backend, so a view can say who paid what.
    package var backends: [UsageEntry.Backend: Share] = [:]

    package init(feature: UsageEntry.Feature) {
        self.feature = feature
    }

    /// One row per feature with at least one call since `start`, in
    /// `Feature.allCases` order.
    package static func summarize(_ entries: [UsageEntry], since start: Date?) -> [FeatureUsage] {
        var byFeature: [UsageEntry.Feature: FeatureUsage] = [:]
        for entry in entries where start.map({ entry.date >= $0 }) ?? true {
            var usage = byFeature[entry.feature] ?? FeatureUsage(feature: entry.feature)
            var share = usage.backends[entry.backend] ?? Share()
            usage.calls += 1
            share.calls += 1
            usage.promptTokens += entry.promptTokens ?? 0
            usage.completionTokens += entry.completionTokens ?? 0
            usage.audioSeconds += entry.audioSeconds ?? 0
            usage.costEUR += entry.costEUR ?? 0
            share.costEUR += entry.costEUR ?? 0
            usage.agentCostUSD += entry.agentCostUSD ?? 0
            share.agentCostUSD += entry.agentCostUSD ?? 0
            usage.costUSD += entry.costUSD ?? 0
            share.costUSD += entry.costUSD ?? 0
            let isPaid = entry.backend != .bundledHelper && entry.backend != .userServer
            if isPaid && entry.costEUR == nil && entry.agentCostUSD == nil && entry.costUSD == nil {
                usage.unpricedPaidCalls += 1
                share.unpricedCalls += 1
            }
            usage.backends[entry.backend] = share
            byFeature[entry.feature] = usage
        }
        return UsageEntry.Feature.allCases.compactMap { byFeature[$0] }
    }

    /// The Insights row's value: the call count, then who paid what, e.g.
    /// "1,040 · €0.62 · 610 free on this Mac" or "150 · $14.90 of Claude
    /// usage". A backend's calls with no price say so rather than read as
    /// free: "150 on Jev (unpriced)", "€0.42 + 2 unpriced".
    package func line(locale: Locale = .current) -> String {
        var parts = [WidgetFormat.count(calls, locale: locale)]
        if audioSeconds > 0 {
            parts.append(WidgetFormat.duration(audioSeconds))
        }
        if let mistral = backends[.mistral] {
            parts.append(
                Self.priced(mistral, cost: mistral.costEUR, format: WidgetFormat.cost, on: "Mistral", locale: locale))
        }
        if let jev = backends[.jev] {
            parts.append(
                Self.priced(jev, cost: jev.costUSD, format: { "\(Self.usd($0)) on Jev" }, on: "Jev", locale: locale))
        }
        let free = (backends[.bundledHelper]?.calls ?? 0) + (backends[.userServer]?.calls ?? 0)
        if free > 0 {
            parts.append("\(WidgetFormat.count(free, locale: locale)) free on this Mac")
        }
        for backend in UsageEntry.Backend.allCases where backend.isAgent {
            guard let share = backends[backend] else { continue }
            let name = Self.agentName(backend)
            parts.append(
                Self.priced(share, cost: share.agentCostUSD, format: { "\(Self.usd($0)) of \(name) usage" },
                            on: name, locale: locale))
        }
        return parts.joined(separator: " · ")
    }

    /// The cost, with any calls it leaves out beside it; a share with no
    /// priced call at all is only counted.
    private static func priced(
        _ share: Share, cost: Double, format: (Double) -> String, on backend: String, locale: Locale
    ) -> String {
        guard share.unpricedCalls < share.calls else {
            return unpriced(share.calls, on: backend, locale: locale)
        }
        let text = format(cost)
        guard share.unpricedCalls > 0 else { return text }
        return "\(text) + \(WidgetFormat.count(share.unpricedCalls, locale: locale)) unpriced"
    }

    private static func unpriced(_ calls: Int, on backend: String, locale: Locale) -> String {
        "\(WidgetFormat.count(calls, locale: locale)) on \(backend) (unpriced)"
    }

    private static func usd(_ value: Double) -> String {
        if value > 0, value < 0.01 { return "< $0.01" }
        return String(format: "$%.2f", value)
    }

    /// Named for the plan that pays, not the harness: a Claude Code run
    /// spends Claude usage.
    private static func agentName(_ backend: UsageEntry.Backend) -> String {
        switch backend {
        case .claudeCode: return "Claude"
        case .codex: return "Codex"
        case .opencode: return "opencode"
        case .vibe: return "Vibe"
        case .mistral, .jev, .bundledHelper, .userServer: return backend.rawValue
        }
    }
}

extension UsageEntry.Feature {
    /// The feature's row title in Insights → Usage by feature.
    package var label: String {
        switch self {
        case .dictation: return "Dictation"
        case .polish: return "Polishing"
        case .secondPass: return "Second pass"
        case .termSuggestions: return "Term suggestions"
        case .projectTerms: return "Project terms"
        case .quickCaptureRouting: return "Quick-capture routing"
        case .quickCaptureDrafting: return "Quick-capture drafting"
        case .quickCapturePolish: return "Quick-capture polishing"
        }
    }
}

/// The local record of every model request: an append-only JSON-lines file
/// under Application Support, one line per request. Kept in memory as well so
/// Settings can sum any window without touching the disk.
package final class UsageLedger: UsageRecording, @unchecked Sendable {
    private struct State {
        var entries: [UsageEntry]?
    }

    package let fileURL: URL?
    private let state = Mutex(State())
    private let writeQueue = DispatchQueue(label: "localvoxtral.usage-ledger", qos: .utility)
    private let onChange: (@Sendable () -> Void)?

    /// `fileURL` nil keeps the ledger in memory only (tests, previews). The
    /// file is read on a background queue right away, so the first Settings
    /// render does not pay for it on the main thread.
    package init(fileURL: URL?, onChange: (@Sendable () -> Void)? = nil) {
        self.fileURL = fileURL
        self.onChange = onChange
        if fileURL != nil {
            writeQueue.async { [self] in _ = entries() }
        }
    }

    /// Named for the one backend it recorded before #837; kept so the history
    /// it holds carries on.
    package static func defaultFileURL() -> URL {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        return applicationSupport
            .appendingPathComponent("localvoxtral", isDirectory: true)
            .appendingPathComponent("mistral-usage.jsonl")
    }

    package func record(_ entry: UsageEntry) {
        let line: Data?
        do {
            line = try Self.encoder.encode(entry) + Data("\n".utf8)
        } catch {
            Log.persistence.error(
                "usage: encode failed: \(error.localizedDescription, privacy: .public)")
            line = nil
        }
        state.withLock { s in
            if s.entries == nil { s.entries = loadEntries() }
            s.entries?.append(entry)
        }
        Log.persistence.info(
            "usage: \(entry.feature.rawValue, privacy: .public) backend=\(entry.backend.rawValue, privacy: .public) model=\(entry.model, privacy: .public) audioSeconds=\(entry.audioSeconds ?? 0, privacy: .public) promptTokens=\(entry.promptTokens ?? -1, privacy: .public) completionTokens=\(entry.completionTokens ?? -1, privacy: .public) costEUR=\(entry.costEUR ?? -1, privacy: .public) agentCostUSD=\(entry.agentCostUSD ?? -1, privacy: .public)"
        )
        // Synchronous: one short append, and a line still queued when the app
        // quits would be lost. Callers are socket, network and process
        // threads, never the main thread.
        if let fileURL, let line {
            writeQueue.sync {
                Self.append(line, to: fileURL)
            }
        }
        onChange?()
    }

    package func entries() -> [UsageEntry] {
        state.withLock { s in
            if s.entries == nil { s.entries = loadEntries() }
            return s.entries ?? []
        }
    }

    package func summary(for period: MistralUsagePeriod, now: Date = Date()) -> MistralUsageSummary {
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

    /// A line that does not decode (a torn write, a hand edit, a feature from
    /// a newer build) is skipped, not fatal: losing one request's cost beats
    /// losing the ledger.
    package static func entries(fromFileContents data: Data) -> [UsageEntry] {
        data.split(separator: UInt8(ascii: "\n")).compactMap { line in
            try? decoder.decode(UsageEntry.self, from: Data(line))
        }
    }

    private func loadEntries() -> [UsageEntry] {
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
                    Log.persistence.error("usage: could not create \(fileURL.path, privacy: .public)")
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
                "usage: append failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

extension UsageLedger: RealtimeUsageRecording {
    package func recordRealtimeDictation(
        date: Date, backend: UsageEntry.Backend, model: String, audioSeconds: Double
    ) {
        record(
            UsageEntry(
                date: date,
                feature: .dictation,
                backend: backend,
                model: model,
                audioSeconds: audioSeconds,
                costEUR: backend == .mistral
                    ? MistralPricing.dictationCost(model: model, audioSeconds: audioSeconds) : nil
            )
        )
    }
}
