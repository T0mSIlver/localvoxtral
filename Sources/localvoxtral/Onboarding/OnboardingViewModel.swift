import Foundation
import Observation

/// Drives the first-launch onboarding wizard: page order, the polishing-download
/// consent choice, kicking off downloads, and the terminal actions (finish, skip,
/// "I run my own server"). Pure state + injected seams (`settings`, the shared
/// `DictationViewModel`, and an `OnboardingBootstrapDriving`) so the whole flow
/// is unit-testable without presenting a window.
@MainActor
@Observable
final class OnboardingViewModel {
    enum Page: Int, CaseIterable, Identifiable, Sendable {
        case welcome
        case permissions
        case downloads
        case finish

        var id: Int { rawValue }
    }

    private(set) var page: Page = .welcome

    /// Consent to download the polishing LLM during setup. Default ON;
    /// declining skips the polishing download now (it downloads later, the first
    /// time polishing is enabled in Settings).
    var polishingConsent = true

    /// True once the user has explicitly kicked off downloads on the Downloads
    /// page. Nothing installs or spawns before this — preserving the app's
    /// lazy-bootstrap invariant.
    private(set) var downloadsStarted = false

    let settings: SettingsStore
    let viewModel: DictationViewModel
    let driver: any OnboardingBootstrapDriving

    /// Set by the window controller to dismiss the wizard.
    @ObservationIgnored var onRequestClose: (() -> Void)?
    /// Set by the window controller to open Settings on the Endpoints tab.
    @ObservationIgnored var onOpenEndpointsSettings: (() -> Void)?

    init(
        settings: SettingsStore,
        viewModel: DictationViewModel,
        driver: any OnboardingBootstrapDriving
    ) {
        self.settings = settings
        self.viewModel = viewModel
        self.driver = driver
    }

    // MARK: - Navigation

    var canGoBack: Bool { page != Page.allCases.first }
    var isFinalPage: Bool { page == Page.allCases.last }

    func advance() {
        guard let next = Page(rawValue: page.rawValue + 1) else {
            finish()
            return
        }
        page = next
    }

    func goBack() {
        guard let previous = Page(rawValue: page.rawValue - 1) else { return }
        page = previous
    }

    // MARK: - Downloads

    /// Kick off managed install + model download for dictation, and for polishing
    /// only if the user consented. Enabling polishing here so the downloaded
    /// model is actually used; declining leaves it off (and undownloaded).
    func startDownloads() {
        guard !downloadsStarted else { return }
        downloadsStarted = true

        // Downloading managed backends only makes sense in managed mode.
        // Matters for Re-run Setup: a user who previously switched to
        // External URL and now chooses the managed download path must end
        // up actually using what was downloaded.
        viewModel.applyDictationBackendModeChange(.managedLocal)
        if polishingConsent {
            viewModel.applyPolishingBackendModeChange(.managedLocal)
            settings.llmPolishingEnabled = true
        }
        driver.start(dictation: true, polishing: polishingConsent)
    }

    /// The "I run my own server instead" escape hatch: point both backends at
    /// external URLs, finish onboarding, and jump the user to the Endpoints tab.
    func useOwnServer() {
        driver.cancel()
        // Undo any polishing opt-in from this wizard run: leaving it enabled
        // against the unconfigured default external URL would make every
        // overlay commit fire a silently failing polish request. The user
        // re-enables it once their endpoint is configured.
        settings.llmPolishingEnabled = false
        viewModel.applyDictationBackendModeChange(.externalURL)
        viewModel.applyPolishingBackendModeChange(.externalURL)
        completeOnboarding()
        onOpenEndpointsSettings?()
        onRequestClose?()
    }

    // MARK: - Completion

    /// Finish the wizard normally (the Finish page's primary action).
    func finish() {
        completeOnboarding()
        onRequestClose?()
    }

    /// Skip the wizard. Closing the window (red button) routes here too, so
    /// dismissal always marks onboarding complete.
    func skip() {
        completeOnboarding()
        onRequestClose?()
    }

    /// Idempotent flag flip. Kept separate so window-close and explicit actions
    /// can both mark completion without double-dismissing.
    func completeOnboarding() {
        if !settings.onboardingCompleted {
            settings.onboardingCompleted = true
        }
    }

    // MARK: - Finish page

    var triggerSummary: DictationTriggerSummary {
        DictationTriggerSummary.make(settings: settings)
    }
}
