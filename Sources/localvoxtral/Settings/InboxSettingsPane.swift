import SwiftUI

/// Quick captures waiting for the user (#725): the words as dictated, the
/// project the router chose, and the agent's draft. Edit it, move it, discard
/// it, or File it; File is the only way anything reaches GitHub.
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
        .font(.callout)
        .foregroundStyle(.secondary)
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
        if let related = item.relatedIssue, item.relation != .none {
            Text(item.relation == .duplicate ? "Duplicates #\(related)" : "Extends #\(related)")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        if item.projectKey != nil, !QuickCaptureInbox.isRepository(item.repository) {
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
            Button("File") { _ = model.file(item.id) }
                .disabled(!item.canFile)
                .accessibilityIdentifier("inbox.row.file")
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

    @ViewBuilder
    private var filed: some View {
        HStack(spacing: 8) {
            Text(item.title)
                .lineLimit(1)
            Spacer(minLength: 8)
            if let url = item.filedURL.flatMap(URL.init(string:)) {
                Link("Open issue", destination: url)
            }
        }
        .font(.callout)
    }
}
