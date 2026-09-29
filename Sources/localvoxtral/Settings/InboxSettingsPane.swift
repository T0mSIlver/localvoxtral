import SwiftUI

/// Quick captures waiting for the user (#725): the words as dictated, the
/// project the router chose, and the draft, sorted by kind (#918). Edit it,
/// move it, discard it, or File an issue; File, and Comment on #N for a draft
/// that extends an open issue (#965), are the only ways anything reaches
/// GitHub. A question shows its answer; a task or a note stays here. A
/// follow-up that joined a capture shows under its words, with Split.
struct InboxSettingsPane: View {
    /// Nil in a view model that runs no services (previews, tests).
    let inbox: QuickCaptureInboxViewModel?

    var body: some View {
        SettingsPage(tab: .inbox) {
            SettingsGroup(title: "Captures") {
                if let inbox, !inbox.items.isEmpty {
                    ForEach(inbox.items) { item in
                        InboxCaptureRow(item: item, inbox: inbox)
                    }
                } else {
                    SettingsGroupRow {
                        Text("No captures. Set a Quick capture shortcut in Dictation.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

private struct InboxCaptureRow: View {
    let item: QuickCaptureItem
    let inbox: QuickCaptureInboxViewModel

    private var model: QuickCaptureInboxModel { inbox.model }
    private var isEditable: Bool { item.state == .ready }

    var body: some View {
        SettingsGroupRow {
            VStack(alignment: .leading, spacing: 8) {
                header
                Text(item.text)
                    .textSelection(.enabled)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                followUps
                if let note = item.note {
                    Text(note)
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
                if item.state == .filed {
                    filed
                } else {
                    draft
                    actions
                }
            }
        }
        .accessibilityIdentifier("inbox.row")
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text(DictationHistoryRowText.timestamp(for: item.capturedAt, now: Date()))
            Spacer(minLength: 8)
            switch item.state {
            case .routing, .drafting, .filing:
                ProgressView().controlSize(.small)
                Text(item.state == .routing ? "Routing" : item.state == .drafting ? "Drafting" : "Filing")
            case .ready, .filed:
                EmptyView()
            }
            if let kind = item.kind, item.state != .filed {
                Text(Self.label(for: kind))
                    .fontWeight(.medium)
                    .accessibilityIdentifier("inbox.row.kind")
            }
            if item.state == .filed {
                Text(item.repository ?? "")
            } else {
                Picker("Project", selection: projectBinding) {
                    Text("No project").tag(String?.none)
                    ForEach(model.projectChoices, id: \.key) { project in
                        Text(project.name).tag(String?.some(project.key))
                    }
                }
                .labelsHidden()
                .fixedSize()
                .disabled(!isEditable)
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    /// Each follow-up's words (#965), with Split beside them while the
    /// capture can still change.
    @ViewBuilder
    private var followUps: some View {
        ForEach(item.followUps ?? []) { followUp in
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(followUp.text)
                    .textSelection(.enabled)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if item.state == .ready || item.state == .drafting {
                    Button("Split") { _ = model.split(followUp.id, from: item.id) }
                        .controlSize(.small)
                        .accessibilityIdentifier("inbox.row.split")
                }
            }
        }
    }

    static func label(for kind: QuickCaptureKind) -> String {
        switch kind {
        case .issue: "Issue"
        case .question: "Question"
        case .task: "Task"
        case .note: "Note"
        }
    }

    private var projectBinding: Binding<String?> {
        Binding(
            get: { item.projectKey },
            set: { _ = model.move(item.id, toProjectKey: $0) }
        )
    }

    @ViewBuilder
    private var draft: some View {
        TextField("Title", text: Binding(
            get: { item.title },
            set: { model.setTitle($0, for: item.id) }
        ))
        .textFieldStyle(.roundedBorder)
        .disabled(!isEditable)
        TextEditor(text: Binding(
            get: { item.body },
            set: { model.setBody($0, for: item.id) }
        ))
        .font(.body.monospaced())
        .frame(minHeight: 120, maxHeight: 240)
        .disabled(!isEditable)
        codeCheck
        if let related = item.relatedIssue, item.relation != .none {
            Text(item.relation == .duplicate ? "Duplicates #\(related)" : "Extends #\(related)")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        if item.isIssue, item.projectKey != nil, !QuickCaptureInbox.isRepository(item.repository) {
            TextField("owner/repository", text: Binding(
                get: { item.repository ?? "" },
                set: { model.setRepository($0, for: item.id) }
            ))
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: 260)
            .disabled(!isEditable)
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            // The router's guess under its bar (#938); nothing drafts
            // until this click or a move.
            if let suggestion = item.suggestion, item.projectKey == nil {
                Button("Move to \(suggestion.projectName)") { _ = model.acceptSuggestion(item.id) }
                    .disabled(!isEditable)
                    .accessibilityIdentifier("inbox.row.suggestion")
            }
            if item.isIssue {
                Button("File") { _ = model.file(item.id) }
                    .disabled(!item.canFile)
                    .accessibilityIdentifier("inbox.row.file")
            }
            if item.relation == .extends, let issue = item.relatedIssue, item.isIssue {
                Button("Comment on #\(issue)") { _ = model.comment(item.id) }
                    .disabled(!item.canComment)
                    .accessibilityIdentifier("inbox.row.comment")
            }
            if item.canDraftAgain {
                Button("Draft Again") { _ = model.draftAgain(item.id) }
                    .accessibilityIdentifier("inbox.row.draftAgain")
            }
            Button("Discard", role: .destructive) { model.discard(item.id) }
                .disabled(!isEditable)
            Spacer(minLength: 8)
            if let repository = item.repository {
                Text(repository)
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }
        }
        .controlSize(.small)
    }

    /// Where an issue's draft stands against the code: the agent still
    /// reading, or the files it read once it checked.
    @ViewBuilder
    private var codeCheck: some View {
        if let check = item.codeCheck {
            switch check.state {
            case .checking:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Checking against the code")
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            case .checked:
                DisclosureGroup {
                    Text(check.filesRead.joined(separator: "\n"))
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } label: {
                    Label(
                        check.keptEdits ? "Checked against the code; your edits kept" : "Checked against the code",
                        systemImage: "checkmark.seal"
                    )
                    .font(.callout)
                    .foregroundStyle(.green)
                }
                .disabled(check.filesRead.isEmpty)
                .accessibilityIdentifier("inbox.row.checked")
            case .failed:
                EmptyView()
            }
        }
    }

    @ViewBuilder
    private var filed: some View {
        HStack(spacing: 8) {
            Text(item.title)
                .lineLimit(1)
            Spacer(minLength: 8)
            if let url = item.filedURL.flatMap(URL.init(string:)) {
                Link(item.commentedOn.map { "Open comment on #\($0)" } ?? "Open issue", destination: url)
            }
        }
        .font(.callout)
    }
}
