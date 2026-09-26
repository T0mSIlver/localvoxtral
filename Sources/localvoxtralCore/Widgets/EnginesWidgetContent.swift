import Foundation

/// The widget sizes the content mappings distinguish.
package enum WidgetSize: String, Sendable, CaseIterable {
    case small
    case medium
    case large
}

/// What the Engines widget draws, from the snapshot alone (#630).
package struct EnginesWidgetContent: Equatable, Sendable {
    package struct Row: Equatable, Sendable {
        package var role: WidgetSnapshot.EngineRole
        /// "Speech" or "Polish".
        package var title: String
        /// "Ready", "Starting", "Mistral API", "External URL"; nil when
        /// `model` says it all ("Off").
        package var status: String?
        /// Short name on small, full name on medium; "Off" with polish off.
        package var model: String?
        /// Memory on this Mac, or today's spend: "4.2 GB", "€0.03".
        package var trailing: String?
        /// A second line: "Mistral API · 18 min today", or "€0.01 today".
        package var detail: String?
        /// Right of `detail`: "€0.41 / 30 d".
        package var detailTrailing: String?

        package init(
            role: WidgetSnapshot.EngineRole,
            title: String,
            status: String? = nil,
            model: String? = nil,
            trailing: String? = nil,
            detail: String? = nil,
            detailTrailing: String? = nil
        ) {
            self.role = role
            self.title = title
            self.status = status
            self.model = model
            self.trailing = trailing
            self.detail = detail
            self.detailTrailing = detailTrailing
        }
    }

    /// One engine's share of the Mac's memory, for the bar or ring.
    package struct MemorySegment: Equatable, Sendable {
        package var role: WidgetSnapshot.EngineRole
        package var fraction: Double

        package init(role: WidgetSnapshot.EngineRole, fraction: Double) {
            self.role = role
            self.fraction = fraction
        }
    }

    package enum Footer: Equatable, Sendable {
        /// Managed engines against the Mac's RAM. `amount` is "7.1",
        /// `caption` "of 32 GB memory" (medium) or "7.1 of 32 GB memory"
        /// (small).
        case memory(segments: [MemorySegment], amount: String, caption: String)
        /// No engine runs here and one bills: "€1.12", "last 30 days".
        case spend(amount: String, caption: String)
        /// Neither: your own servers.
        case none(caption: String)
    }

    package enum Layout: Equatable, Sendable {
        case rows([Row], footer: Footer)
        /// Small, both engines on the Mistral API: spend replaces the rows.
        case hostedSpend(amount: String, caption: String, lines: [Line])
        case downloading(role: WidgetSnapshot.EngineRole, title: String, fraction: Double?, caption: String)
        /// A failed helper, or the app quit. One sentence and a hint; the
        /// other engine's row when it still works.
        case stopped(title: String, detail: String, other: Row?)
    }

    package struct Line: Equatable, Sendable {
        package var label: String
        package var value: String

        package init(label: String, value: String) {
            self.label = label
            self.value = value
        }
    }

    package var title = "Engines"
    /// Beside the title: "Mistral API" when both engines are hosted there.
    package var titleDetail: String?
    package var layout: Layout
    /// Medium only, and only while polish is on and the app can act on it.
    package var showsTurnOffPolish: Bool

    package init(title: String = "Engines", titleDetail: String? = nil, layout: Layout, showsTurnOffPolish: Bool) {
        self.title = title
        self.titleDetail = titleDetail
        self.layout = layout
        self.showsTurnOffPolish = showsTurnOffPolish
    }

    package init(_ engines: WidgetSnapshot.Engines, size: WidgetSize, locale: Locale = .current) {
        let mapper = Mapper(engines: engines, size: size, locale: locale)
        self = mapper.content()
    }

    private struct Mapper {
        let engines: WidgetSnapshot.Engines
        let size: WidgetSize
        let locale: Locale

        var isSmall: Bool { size == .small }

        /// The engines that count: polish only while it is on.
        var activeRoles: [WidgetSnapshot.EngineRole] {
            engines.polishEnabled ? [.speech, .polish] : [.speech]
        }

        func engine(_ role: WidgetSnapshot.EngineRole) -> WidgetSnapshot.Engine {
            engines.engine(role)
        }

        func content() -> EnginesWidgetContent {
            let turnOff = !isSmall && engines.polishEnabled && engines.appRunning

            if !engines.appRunning {
                return EnginesWidgetContent(
                    layout: .stopped(title: "localvoxtral is not running", detail: "Open it to start its engines.", other: nil),
                    showsTurnOffPolish: false
                )
            }

            let managed = activeRoles.filter { engine($0).mode == .managedLocal }
            if let role = managed.first(where: { if case .downloading = engine($0).state { return true } else { return false } }),
               case let .downloading(done, total, paused) = engine(role).state {
                return EnginesWidgetContent(
                    layout: .downloading(
                        role: role,
                        title: paused
                            ? "The \(role == .speech ? "speech" : "polish") model download is paused"
                            : "Downloading the \(role == .speech ? "speech" : "polish") model",
                        fraction: total.flatMap { $0 > 0 ? min(1, Double(done) / Double($0)) : nil },
                        caption: downloadCaption(done: done, total: total)
                    ),
                    showsTurnOffPolish: turnOff
                )
            }

            let failed = managed.filter { engine($0).state == .failed }
            if !failed.isEmpty {
                if failed.count == 2 {
                    return EnginesWidgetContent(
                        layout: .stopped(title: "Engines stopped", detail: "Open localvoxtral to restart them.", other: nil),
                        showsTurnOffPolish: turnOff
                    )
                }
                let role = failed[0]
                let others = [WidgetSnapshot.EngineRole.speech, .polish].filter { $0 != role }
                return EnginesWidgetContent(
                    layout: .stopped(
                        title: "\(noun(role)) stopped",
                        detail: "Open localvoxtral to restart it.",
                        other: others.first.map { compactRow($0) }
                    ),
                    showsTurnOffPolish: turnOff
                )
            }

            let hosted = activeRoles.allSatisfy { engine($0).mode == .mistralAPI }
            if hosted, isSmall, engines.polishEnabled {
                let mistral = engines.mistral
                return EnginesWidgetContent(
                    titleDetail: "Mistral API",
                    layout: .hostedSpend(
                        amount: WidgetFormat.cost(mistral.last30DaysEUR),
                        caption: "last 30 days",
                        lines: [
                            Line(label: "Today", value: WidgetFormat.cost(mistral.todayEUR)),
                            Line(label: "Audio today", value: WidgetFormat.duration(mistral.audioSecondsToday)),
                        ]
                    ),
                    showsTurnOffPolish: false
                )
            }

            return EnginesWidgetContent(
                layout: .rows([row(.speech), row(.polish)], footer: footer()),
                showsTurnOffPolish: turnOff
            )
        }

        func noun(_ role: WidgetSnapshot.EngineRole) -> String {
            role == .speech ? "Speech engine" : "Polish engine"
        }

        func title(_ role: WidgetSnapshot.EngineRole) -> String {
            role == .speech ? "Speech" : "Polish"
        }

        func modelName(_ engine: WidgetSnapshot.Engine) -> String? {
            isSmall ? (engine.shortModelName ?? engine.modelName) : (engine.modelName ?? engine.shortModelName)
        }

        func stateText(_ state: WidgetSnapshot.EngineState) -> String {
            switch state {
            case .ready: return "Ready"
            case .starting: return "Starting"
            case .downloading: return "Downloading"
            case .idle: return "Not loaded"
            case .failed: return "Stopped"
            }
        }

        func row(_ role: WidgetSnapshot.EngineRole) -> Row {
            if role == .polish, !engines.polishEnabled {
                return Row(role: role, title: title(role), model: "Off")
            }
            let engine = engine(role)
            switch engine.mode {
            case .managedLocal:
                return Row(
                    role: role,
                    title: title(role),
                    status: stateText(engine.state),
                    model: modelName(engine),
                    trailing: engine.memoryBytes.map { WidgetFormat.memory($0, locale: locale) }
                )
            case .externalURL:
                return Row(role: role, title: title(role), status: "External URL")
            case .mistralAPI:
                let mistral = engines.mistral
                let today = role == .speech ? mistral.speechTodayEUR : mistral.polishTodayEUR
                let month = role == .speech ? mistral.speechLast30DaysEUR : mistral.polishLast30DaysEUR
                if isSmall {
                    return Row(
                        role: role,
                        title: title(role),
                        status: "Mistral API",
                        detail: "\(WidgetFormat.cost(today)) today",
                        detailTrailing: "\(WidgetFormat.cost(month)) / 30 d"
                    )
                }
                let usage = role == .speech
                    ? "\(WidgetFormat.duration(mistral.audioSecondsToday)) today"
                    : (mistral.polishesToday == 1 ? "1 polish today" : "\(mistral.polishesToday) polishes today")
                return Row(
                    role: role,
                    title: title(role),
                    model: "Mistral API · \(usage)",
                    trailing: WidgetFormat.cost(today)
                )
            }
        }

        /// "Polish · Ready · 2.9 GB", beside a stopped engine.
        func compactRow(_ role: WidgetSnapshot.EngineRole) -> Row {
            var full = row(role)
            if let trailing = full.trailing, let status = full.status {
                full.status = "\(status) · \(trailing)"
                full.trailing = nil
            }
            full.model = nil
            full.detail = nil
            full.detailTrailing = nil
            return full
        }

        func footer() -> Footer {
            let managed = activeRoles.filter { engine($0).mode == .managedLocal }
            if !managed.isEmpty {
                let physical = max(engines.physicalMemoryBytes, 1)
                let used = managed.compactMap { engine($0).memoryBytes }.reduce(0, +)
                let segments = managed.compactMap { role in
                    engine(role).memoryBytes.map { MemorySegment(role: role, fraction: Double($0) / Double(physical)) }
                }
                let amount = WidgetFormat.memoryNumber(used, locale: locale)
                let total = WidgetFormat.memory(engines.physicalMemoryBytes, locale: locale)
                return .memory(
                    segments: segments,
                    amount: amount,
                    caption: isSmall ? "\(amount) of \(total) memory" : "of \(total) memory"
                )
            }
            if activeRoles.contains(where: { engine($0).mode == .mistralAPI }) {
                return .spend(amount: WidgetFormat.cost(engines.mistral.last30DaysEUR), caption: "last 30 days")
            }
            return .none(caption: "No local model in memory")
        }

        func downloadCaption(done: Int64, total: Int64?) -> String {
            let doneText = WidgetFormat.downloadNumber(done, locale: locale)
            guard let total, total > 0 else { return "\(doneText) GB" }
            let percent = WidgetFormat.percent(min(1, Double(done) / Double(total)))
            return "\(doneText) of \(WidgetFormat.downloadNumber(total, locale: locale)) GB · \(percent)"
        }
    }
}
