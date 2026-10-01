import SwiftUI

/// A store whose file this build could not load (#989): says so, and offers
/// Start Over, which renames the file beside itself and begins empty. Shown
/// only while the store refuses its file.
struct StoredFileProblemRow: View {
    let problem: StoredFileProblem
    let fileName: String
    /// Said in the confirmation, after the rename.
    var consequence: String?
    let startOver: @MainActor () async throws -> Void

    @State private var isConfirming = false
    @State private var failed = false

    var body: some View {
        SettingsGroupRow {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(Self.sentence(for: problem, fileName: fileName))
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Start Over…") { isConfirming = true }
                    .accessibilityIdentifier("settings.storedFile.startOver")
            }
        }
        .confirmationDialog("Start over with an empty \(fileName)?", isPresented: $isConfirming) {
            Button("Start Over", role: .destructive) {
                Task {
                    do { try await startOver() } catch { failed = true }
                }
            }
        } message: {
            Text(["The file is renamed, not deleted, and stays in its folder.", consequence].compactMap { $0 }
                .joined(separator: " "))
        }
        .alert("\(fileName) could not be renamed", isPresented: $failed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("It is still in place, and still not written.")
        }
    }

    static func sentence(for problem: StoredFileProblem, fileName: String) -> String {
        switch problem {
        case .unreadable:
            "\(fileName) could not be read. It is left as it is, and nothing new is saved."
        case .newerVersion:
            "\(fileName) is from a newer localvoxtral. It is left as it is, and nothing new is saved."
        }
    }
}
