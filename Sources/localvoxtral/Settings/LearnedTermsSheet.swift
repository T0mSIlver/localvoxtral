import SwiftUI

/// Every learned term, one row each, grouped by project: how often the memory
/// applied it, when it last did, and a pin and a forget button (#522).
///
/// Reads the store's in-memory snapshot like the Settings row does, and
/// re-renders on the same revision counter, so a dictation that lands while
/// the sheet is open shows up in it.
struct LearnedTermsSheet: View {
    let viewModel: DictationViewModel
    let onDone: () -> Void

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
            HStack {
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
