import SwiftUI

/// The first-launch onboarding wizard: Welcome → Permissions → Downloads →
/// Finish. All state and side effects live in `OnboardingViewModel`; this view
/// is presentation only.
struct OnboardingWizardView: View {
    @Bindable var model: OnboardingViewModel

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                pageContent
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(28)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            footer
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
        }
        .frame(width: 540, height: 480)
    }

    @ViewBuilder
    private var pageContent: some View {
        switch model.page {
        case .welcome:
            WelcomePage()
        case .permissions:
            PermissionsPage(viewModel: model.viewModel)
        case .downloads:
            DownloadsPage(model: model)
        case .finish:
            FinishPage(summary: model.triggerSummary)
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if model.canGoBack {
                Button("Back") { model.goBack() }
            }
            if !model.isFinalPage {
                Button("Skip") { model.skip() }
                    .buttonStyle(.link)
            }

            Spacer(minLength: 0)

            Button(primaryActionTitle) {
                performPrimaryAction()
            }
            .keyboardShortcut(.defaultAction)
        }
    }

    private var primaryActionTitle: String {
        if model.page == .downloads, !model.downloadsStarted {
            return "Begin Download"
        }
        return model.isFinalPage ? "Get Started" : "Continue"
    }

    private func performPrimaryAction() {
        if model.page == .downloads, !model.downloadsStarted {
            model.startDownloads()
        } else {
            model.advance()
        }
    }
}

// MARK: - Header

private struct OnboardingHeader: View {
    let systemImage: String
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 34, weight: .regular))
                .foregroundStyle(.tint)

            Text(title)
                .font(.system(size: 22, weight: .semibold))

            Text(subtitle)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Welcome

private struct WelcomePage: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            OnboardingHeader(
                systemImage: "waveform.circle",
                title: "Welcome to localvoxtral",
                subtitle:
                    "Realtime dictation for macOS. Start dictation, speak, and text appears as you talk — right in the app you're using."
            )

            VStack(alignment: .leading, spacing: 12) {
                FeatureBullet(
                    systemImage: "menubar.arrow.up.rectangle",
                    text: "Lives in your menu bar and opens instantly.")
                FeatureBullet(
                    systemImage: "bolt.horizontal.circle",
                    text: "Streams words while you're still speaking.")
                FeatureBullet(
                    systemImage: "lock.laptopcomputer",
                    text: "Runs fully on-device with the managed local engine.")
            }

            Text("This quick setup grants permissions and downloads the local engine.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct FeatureBullet: View {
    let systemImage: String
    let text: String

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 15))
                .foregroundStyle(.tint)
                .frame(width: 22)
            Text(text)
                .font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Permissions

private struct PermissionsPage: View {
    let viewModel: DictationViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            OnboardingHeader(
                systemImage: "hand.raised.circle",
                title: "Grant permissions",
                subtitle:
                    "localvoxtral needs the microphone to hear you, and Accessibility to type text into other apps."
            )

            PermissionRowsView(viewModel: viewModel)

            Text(
                "You can continue without granting these now and enable them later in Settings ▸ General."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Downloads

private struct DownloadsPage: View {
    @Bindable var model: OnboardingViewModel

    private var plannedItems: [OnboardingItemID] {
        var items: [OnboardingItemID] = [.dictation]
        if model.polishingConsent { items.append(.polishing) }
        return items
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            OnboardingHeader(
                systemImage: "arrow.down.circle",
                title: "Set up the local engine",
                subtitle:
                    "localvoxtral will prepare the bundled dictation engine and download its Voxtral model. Nothing downloads until you start it below."
            )

            Toggle(isOn: $model.polishingConsent) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Also set up LLM polishing")
                        .font(.system(size: 13, weight: .medium))
                    Text(
                        "Downloads a small polishing model for the built-in engine. You can decline and turn it on later in Settings."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
            .disabled(model.downloadsStarted)

            VStack(alignment: .leading, spacing: 10) {
                ForEach(plannedItems) { item in
                    DownloadItemRow(
                        item: item,
                        state: model.downloadsStarted ? model.driver.itemStates[item] : nil
                    )
                }
            }

            if model.downloadsStarted {
                Text(
                    "Downloads continue in the background — you can press Continue while they finish."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            Button("I run my own server instead") { model.useOwnServer() }
                .buttonStyle(.link)
                .font(.caption)
        }
    }
}

private struct DownloadItemRow: View {
    let item: OnboardingItemID
    /// nil before downloads start (planned but not yet running).
    let state: OnboardingItemState?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            statusIcon
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.system(size: 13, weight: .medium))
                Text(item.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if case .working(let detail, let fraction) = state ?? .pending {
                    HStack(spacing: 8) {
                        if let fraction {
                            ProgressView(value: fraction)
                                .frame(width: 120)
                                .controlSize(.small)
                        } else {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else if case .failed(let summary) = state ?? .pending {
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch state ?? .pending {
        case .pending:
            Image(systemName: "circle")
                .foregroundStyle(.secondary)
        case .working:
            Image(systemName: "arrow.down.circle")
                .foregroundStyle(.tint)
        case .ready:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        }
    }
}

// MARK: - Finish

private struct FinishPage: View {
    let summary: DictationTriggerSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            OnboardingHeader(
                systemImage: "checkmark.circle",
                title: "You're all set",
                subtitle: "Here's how to start dictating."
            )

            VStack(alignment: .leading, spacing: 6) {
                Text(summary.primary)
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                Text(summary.explanation)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(nsColor: .quaternarySystemFill))
            }

            Text("Press it in any text field to try it out. Escape cancels a dictation.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !summary.isModifierOnly {
                Text(
                    "Prefer a single key? The trigger can be just a modifier like Fn / Globe — tap it for the overlay, hold it to type live. Switch anytime in Settings ▸ Dictation."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
