import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Learned terms, one row each, grouped by project: how often the memory
/// applied it, when it last did, and a pin and a forget button (#522). A
/// coding agent's proposal (#609) is a row like any other: Pin accepts it,
/// Forget removes it.
///
/// Opened from Text Processing, it lists the terms outside the projects
/// quick capture lists, and its footer exports and imports every term, to
/// move them between machines (#523). Opened from a project's sheet in
/// Projects (#939), it lists that project's terms.
///
/// Reads the store's in-memory snapshot like the Settings row does, and
/// re-renders on the same revision counter, so a dictation that lands while
/// the sheet is open shows up in it.
struct LearnedTermsSheet: View {
    let viewModel: DictationViewModel
    /// One project's checkouts, from its sheet in Projects; nil for the
    /// terms outside every project.
    var project: (name: String, keys: [String])? = nil
    let onDone: () -> Void
    @State private var fileMessage: String?

    private var projects: [LearnedTermProject] {
        _ = viewModel.learnedTermRevision
        return LearnedTermsSheet.displayOrder(
            viewModel.learnedTermStore?.snapshot() ?? LearnedTerms(), now: Date(), projectKeys: project?.keys
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(project.map { "\($0.name) terms" } ?? "Learned terms")
                .font(.headline)
            if projects.allSatisfy(\.terms.isEmpty) {
                Text(project == nil ? "No terms outside projects. A project's terms are in Projects." : "No terms yet.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(projects.filter { !$0.terms.isEmpty }, id: \.key) { bucket in
                        Section(bucket.name) {
                            ForEach(bucket.terms, id: \.term) { term in
                                row(term, projectKey: bucket.key)
                            }
                        }
                    }
                }
                .accessibilityIdentifier("settings.learnedTerms.list")
            }
            if let fileMessage {
                Text(fileMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            HStack {
                if project == nil {
                    Button("Import…", action: importTerms)
                        .accessibilityIdentifier("settings.learnedTerms.import")
                    if !(viewModel.learnedTermStore?.snapshot().projects.isEmpty ?? true) {
                        Button("Export…", action: exportTerms)
                            .accessibilityIdentifier("settings.learnedTerms.export")
                    }
                }
                Spacer()
                Button("Done", action: onDone)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 480, idealWidth: 520, minHeight: 360, idealHeight: 440)
    }

    private func row(_ term: LearnedTerm, projectKey: String) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(term.term)
                    .lineLimit(1)
                    .truncationMode(.middle)
                LearnedTermsSheet.detail(for: term)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                viewModel.learnedTermStore?.setPinned(!term.isPinned, term: term.term, projectKey: projectKey)
            } label: {
                Image(systemName: term.isPinned ? "pin.fill" : "pin")
            }
            .buttonStyle(.borderless)
            .help(term.isPinned ? "Unpin" : "Pin: keep it for good and use it now")
            .accessibilityLabel(term.isPinned ? "Unpin \(term.term)" : "Pin \(term.term)")
            Button {
                viewModel.learnedTermStore?.forget(term.term, projectKey: projectKey)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Forget")
            .accessibilityLabel("Forget \(term.term)")
        }
    }

    // MARK: Export and import

    private func exportTerms() {
        fileMessage = nil
        guard let store = viewModel.learnedTermStore else { return }
        let data: Data
        do {
            data = try LearnedTermsExport.data(for: store.snapshot(), exportedAt: Date())
        } catch {
            Log.persistence.error(
                "learned terms: export encode failed: \(error.localizedDescription, privacy: .public)"
            )
            fileMessage = "Could not export the terms."
            return
        }
        let panel = NSSavePanel()
        panel.title = "Export learned terms"
        panel.nameFieldStringValue = LearnedTermsExport.defaultFileName
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            // Off the main actor: the destination can be a network volume.
            let saved = await Task.detached(priority: .userInitiated) {
                do {
                    try data.write(to: url, options: .atomic)
                    Log.persistence.info("learned terms: exported \(data.count, privacy: .public) bytes")
                    return true
                } catch {
                    Log.persistence.error(
                        "learned terms: export write failed: \(error.localizedDescription, privacy: .public)"
                    )
                    return false
                }
            }.value
            fileMessage = saved ? "Exported." : "Could not save the file."
        }
    }

    private func importTerms() {
        fileMessage = nil
        guard let store = viewModel.learnedTermStore else { return }
        let panel = NSOpenPanel()
        panel.title = "Import learned terms"
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            let read = await Task.detached(priority: .userInitiated) {
                Result { try LearnedTermsExport.projects(from: Data(contentsOf: url)) }
            }.value
            switch read {
            case .failure(let error):
                Log.persistence.error(
                    "learned terms: import refused: \(String(describing: error), privacy: .public)"
                )
                fileMessage = LearnedTermsSheet.importRefusal(error)
            case .success(let projects):
                let summary = await withCheckedContinuation { continuation in
                    store.importProjects(projects) { continuation.resume(returning: $0) }
                }
                fileMessage = LearnedTermsSheet.importResult(summary)
            }
        }
    }

    private static func importResult(_ summary: LearnedTermsExport.ImportSummary) -> String {
        switch (summary.terms, summary.projects) {
        case (0, _): "No terms to import."
        case (1, _): "Imported 1 term."
        case (let terms, 1): "Imported \(terms) terms."
        case (let terms, let projects): "Imported \(terms) terms in \(projects) projects."
        }
    }

    private static func importRefusal(_ error: any Error) -> String {
        switch error as? LearnedTermsExport.ImportError {
        case .newerVersion: "Made by a newer version of localvoxtral."
        case .unreadable: "Not a learned terms file."
        case nil: "Could not read the file."
        }
    }

    // MARK: Pure parts, unit-tested

    /// With `projectKeys`, those buckets in that order: one project's
    /// checkouts. Without, the buckets outside quick capture's projects
    /// (`listedProjects`, #891) that hold terms, such as a worktree name from
    /// before #652, most recent first and the shared bucket last; the
    /// listed projects' terms are in Projects (#939). Terms strongest
    /// evidence first, the order the prompt ranks them in.
    nonisolated static func displayOrder(
        _ terms: LearnedTerms, now: Date, projectKeys: [String]? = nil
    ) -> [LearnedTermProject] {
        let buckets: [LearnedTermProject]
        if let projectKeys {
            buckets = projectKeys.compactMap { key in terms.projects.first { $0.key == key } }
        } else {
            let listedKeys = Set(terms.listedProjects(now: now).map(\.key))
            buckets = terms.projects
                .filter { !listedKeys.contains($0.key) && !$0.terms.isEmpty }
                .sorted { lhs, rhs in
                    let lhsShared = lhs.key == LearnedTermProjectResolver.shared.key
                    let rhsShared = rhs.key == LearnedTermProjectResolver.shared.key
                    if lhsShared != rhsShared { return rhsShared }
                    if lhs.lastSeen != rhs.lastSeen { return lhs.lastSeen > rhs.lastSeen }
                    return lhs.key < rhs.key
                }
        }
        return buckets.map { project in
            var sorted = project
            sorted.terms.sort(by: LearnedTerms.isStrongerEvidence)
            return sorted
        }
    }

    /// The line under a term. A term below the bar is still being learned,
    /// or was proposed by the project's coding agent (#609), so it says how
    /// far along it is instead.
    nonisolated static func detailParts(for term: LearnedTerm) -> (text: String, lastApplied: Date?) {
        guard term.isConfirmed(minimumDictations: LearnedTerms.confirmedDictations) else {
            let progress = "heard in \(term.dictations) of \(LearnedTerms.confirmedDictations) dictations"
            if let proposer = term.proposerDisplayName {
                return ("Proposed by \(proposer): \(progress)", nil)
            }
            return ("Learning: \(progress)", nil)
        }
        switch term.appliedCount {
        case 0: return ("Not applied yet", nil)
        case 1: return ("Applied once,", term.lastApplied)
        case let count: return ("Applied \(count) times, last", term.lastApplied)
        }
    }

    private static func detail(for term: LearnedTerm) -> Text {
        let parts = detailParts(for: term)
        guard let lastApplied = parts.lastApplied else { return Text(parts.text) }
        return Text("\(parts.text) \(lastApplied, format: .relative(presentation: .named))")
    }
}
