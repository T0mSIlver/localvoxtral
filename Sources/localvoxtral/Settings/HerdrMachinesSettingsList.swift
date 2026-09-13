import SwiftUI

/// The "Saved herdr machines" list inside the existing Remote hosts group:
/// herdr's saved machines as enrollment sources, one row per machine.
///
/// Content of that group only, never a group of its own — a pane's group
/// structure is constant (owner rule, 2026-07-04). An absent catalog renders
/// nothing at all; an unreadable one renders one short inline sentence; the
/// rows carry the sidebar's dot idiom (PR #284) and an `Import…` button on
/// exactly the rows the model marks importable.
struct HerdrMachinesSettingsList: View {
    let model: ClaudeIntegrationSettingsModel

    var body: some View {
        switch model.herdrMachines {
        case .absent:
            // No catalog: this user never ran `herdr machine add`, and an
            // empty-state row would be noise about a feature they do not use.
            EmptyView()
        case .unreadable:
            HerdrMachineImportMessage("herdr's saved machines could not be read.", color: .orange)
        case .candidates(let candidates):
            VStack(alignment: .leading, spacing: 4) {
                Text("Saved herdr machines")
                    .font(.callout)
                    .accessibilityIdentifier("claude.remote.herdrMachines.title")
                ForEach(candidates) { candidate in
                    HerdrMachineImportRow(candidate: candidate, model: model)
                }
            }
        }
    }
}

/// One saved machine: the sidebar's status dot, the profile's label and
/// target, and — on importable rows — the trailing `Import…` that pre-fills
/// the enrollment form and runs the same consent-gated flow the typed form
/// uses.
private struct HerdrMachineImportRow: View {
    let candidate: HerdrMachineImportCandidate
    let model: ClaudeIntegrationSettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                // The sidebar's dot idiom: a 7pt circle, hidden from
                // accessibility — the dot means what the row's texts and the
                // enrolled-host list above say, never a legend of its own.
                Circle()
                    .fill(candidate.status.dot.color)
                    .frame(width: 7, height: 7)
                    .accessibilityHidden(true)

                Text(candidate.profile.label)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .accessibilityIdentifier("claude.remote.herdrMachines.\(candidate.id).label")

                Text(candidate.profile.target)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .accessibilityIdentifier("claude.remote.herdrMachines.\(candidate.id).target")

                Spacer(minLength: 8)

                if candidate.status == .importable {
                    Button("Import…") {
                        Task { await model.importHerdrMachine(candidate) }
                    }
                    .controlSize(.small)
                    .accessibilityIdentifier("claude.remote.herdrMachines.\(candidate.id).import")
                }
            }

            if let sentence = candidate.status.sentence {
                // Wraps, never truncates — it is an instruction, and an
                // instruction must never be ellipsized (owner rule, PR #282).
                HerdrMachineImportMessage(sentence, color: .secondary)
                    .padding(.leading, 15)
                    .accessibilityIdentifier("claude.remote.herdrMachines.\(candidate.id).sentence")
            }
        }
        // herdr's own off switch: still listed, dimmed, no action.
        .opacity(candidate.status == .disabled ? 0.5 : 1)
    }
}

/// The `SettingsInlineMessage` idiom, kept local so `SettingsView.swift`
/// carries only the one-line insertion of the list itself.
private struct HerdrMachineImportMessage: View {
    let message: String
    let color: Color

    init(_ message: String, color: Color) {
        self.message = message
        self.color = color
    }

    var body: some View {
        Text(message)
            .font(.caption)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The sidebar's fixed dot meanings (PR #284) applied to one saved machine:
/// green when the target is already an enrolled host's alias, yellow when it
/// is detected and one setup step (the import) is pending, grey when there is
/// nothing this pane can do with it.
extension HerdrMachineImportStatus {
    var dot: SettingsStatusDot {
        switch self {
        case .enrolled: return .green
        case .importable: return .yellow
        case .needsAlias, .disabled: return .grey
        }
    }
}
