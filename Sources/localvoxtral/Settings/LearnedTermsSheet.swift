import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Every learned term, one row each, grouped by project: how often the memory
/// applied it, when it last did, and a pin and a forget button (#522). Its
/// footer exports and imports them, to move them between machines (#523).
///
/// Reads the store's in-memory snapshot like the Settings row does, and
/// re-renders on the same revision counter, so a dictation that lands while
/// the sheet is open shows up in it.
struct LearnedTermsSheet: View {
    let viewModel: DictationViewModel
    let onDone: () -> Void
    @State private var fileMessage: String?

    private var projects: [LearnedTermProject] {
        _ = viewModel.learnedTermRevision
        return LearnedTermsSheet.displayOrder(viewModel.learnedTermStore?.snapshot() ?? LearnedTerms())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Learned terms")
                .font(.headline)
            if projects.isEmpty {
                Text("No learned terms.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(projects, id: \.key) { project in
                        Section(project.name) {
                            ForEach(project.terms, id: \.term) { term in
                                row(term, projectKey: project.key)
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
                Button("Import…", action: importTerms)
                    .accessibilityIdentifier("settings.learnedTerms.import")
                if !projects.isEmpty {
                    Button("Export…", action: exportTerms)
                        .accessibilityIdentifier("settings.learnedTerms.export")
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

    /// Projects most recently dictated first, the shared bucket last; terms
    /// strongest evidence first, the order the prompt ranks them in.
    nonisolated static func displayOrder(_ terms: LearnedTerms) -> [LearnedTermProject] {
        terms.projects
            .map { project in
                var sorted = project
                sorted.terms.sort(by: LearnedTerms.isStrongerEvidence)
                return sorted
            }
            .sorted { lhs, rhs in
                let lhsShared = lhs.key == LearnedTermProjectResolver.shared.key
                let rhsShared = rhs.key == LearnedTermProjectResolver.shared.key
                if lhsShared != rhsShared { return rhsShared }
                if lhs.lastSeen != rhs.lastSeen { return lhs.lastSeen > rhs.lastSeen }
                return lhs.key < rhs.key
            }
    }

    /// The line under a term. A term below the bar is still being learned
    /// and is never applied, so it says how far along it is instead.
    nonisolated static func detailParts(for term: LearnedTerm) -> (text: String, lastApplied: Date?) {
        guard term.isConfirmed(minimumDictations: LearnedTerms.confirmedDictations) else {
            return ("Learning: heard in \(term.dictations) of \(LearnedTerms.confirmedDictations) dictations", nil)
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
