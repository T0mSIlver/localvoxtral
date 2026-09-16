import SwiftUI

/// The herdr pane's Saved machines list: herdr's saved machines as
/// enrollment sources, one row per machine.
///
/// The group around it always exists — a pane's group structure is constant
/// (owner rule, 2026-07-04) — so an absent catalog renders one short empty
/// line rather than an empty card; an unreadable one renders one short inline
/// sentence; the rows carry the sidebar's dot idiom (PR #284) and an
/// `Import…` button on exactly the rows the model marks importable.
struct HerdrMachinesSettingsList: View {
    let model: ClaudeIntegrationSettingsModel

    var body: some View {
        switch model.herdrMachines {
        case .absent:
            Text("No saved machines.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("claude.remote.herdrMachines.empty")
        case .unreadable:
            SettingsInlineMessage("herdr's saved machines could not be read.", color: .orange)
        case .candidates(let candidates):
            VStack(alignment: .leading, spacing: 4) {
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
                    // Same re-entrancy condition the import path guards on:
                    // no second enrollment while the sheet is up or running.
                    .disabled(model.presentedPlan != nil || model.isEnrollmentBusy)
                    .accessibilityIdentifier("claude.remote.herdrMachines.\(candidate.id).import")
                }
            }

            if let sentence = candidate.status.sentence {
                // Wraps, never truncates — it is an instruction, and an
                // instruction must never be ellipsized (owner rule, PR #282).
                SettingsInlineMessage(sentence, color: .secondary)
                    .padding(.leading, 15)
                    .accessibilityIdentifier("claude.remote.herdrMachines.\(candidate.id).sentence")
            }
        }
        // herdr's own off switch: still listed, dimmed, no action.
        .opacity(candidate.status == .disabled ? 0.5 : 1)
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
