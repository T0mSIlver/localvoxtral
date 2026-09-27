import SwiftUI

/// One line per project quick capture can route to (#811): what the project
/// is and what it has, in the user's words. The router reads it before the
/// README summary, which says what a project is but rarely what it has
/// (localvoxtral's never names quick capture or the Inbox). The field shows
/// that summary as its placeholder, so the user sees what the router already
/// knows.
struct QuickCaptureProjectLinesSheet: View {
    @Bindable var settings: SettingsStore
    let projects: [QuickCaptureProject]
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Project descriptions")
                .font(.headline)
            if projects.isEmpty {
                Text("No projects. A project appears once you dictate into a coding agent there.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(projects, id: \.key) { project in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(project.name)
                            .frame(width: 140, alignment: .leading)
                            .lineLimit(1)
                        TextField(
                            project.summary ?? "What it is and what it has",
                            text: line(for: project.key),
                            axis: .vertical
                        )
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1...3)
                    }
                }
                .accessibilityIdentifier("settings.quickCaptureProjectLines.list")
            }
            HStack {
                Spacer()
                Button("Done", action: onDone)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 620, height: 420)
    }

    private func line(for key: String) -> Binding<String> {
        Binding(
            get: { settings.quickCaptureProjectLines[key] ?? "" },
            set: { settings.setQuickCaptureProjectLine($0, for: key) }
        )
    }
}
