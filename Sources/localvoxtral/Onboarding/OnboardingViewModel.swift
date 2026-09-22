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
        case engine
        case downloads
        case finish

        var id: Int { rawValue }
    }

    /// Which engine the user picked on the `.engine` page. Also decides the
    /// page order: the Mistral path has nothing to download.
    enum EngineChoice: String, CaseIterable, Identifiable, Sendable {
        case local
        case mistralAPI

        var id: String { rawValue }
    }

    private(set) var page: Page = .welcome

    /// Default local: the app's promise is that dictation works with nothing
    /// leaving the Mac, and a wizard that defaults to a hosted API would ship
    /// a different product than the one on the box.
    var engineChoice: EngineChoice = .local

    /// The key typed on the `.engine` page. Wizard-local until Continue: a
    /// half-typed key must not land in Settings, and nothing is persisted for a
    /// user who backs out.
    var mistralAPIKeyDraft = ""

    /// Result of the `.engine` page's own "Check key" press. Advisory — a
    /// rejected key does not block Continue, because the check can be wrong
    /// (offline, proxy, a key minted seconds ago) and the user owns the choice.
    var mistralAPIKeyCheckState: MistralAPIKeyCheckState = .idle

    /// The in-flight check. Kept awaitable so the unit suite observes the
    /// result without polling a clock.
    @ObservationIgnored private(set) var mistralAPIKeyCheckTask: Task<Void, Never>?

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
    /// Set by the window controller to open Settings on the Engines tab.
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

    /// The pages this run actually shows. Picking Mistral removes `.downloads`
    /// outright — there is nothing to download, and a page that says so would
    /// be a step the user has to dismiss.
    var pageOrder: [Page] {
        switch engineChoice {
        case .local:
            return Page.allCases
        case .mistralAPI:
            return [.welcome, .permissions, .engine, .finish]
        }
    }

    var canGoBack: Bool { page != pageOrder.first }
    var isFinalPage: Bool { page == pageOrder.last }

    /// Whether the primary button may move on. Only the Mistral engine choice
    /// can block it, and only for want of a key to store.
    var canContinue: Bool {
        guard page == .engine, engineChoice == .mistralAPI else { return true }
        return !mistralAPIKeyDraft.trimmed.isEmpty
    }

    func advance() {
        guard canContinue else { return }

        // Leaving the engine page with Mistral chosen IS the setup: it stores
        // the key and switches both engines, so nothing needs downloading and
        // the driver must never be started.
        if page == .engine, engineChoice == .mistralAPI {
            applyMistralEngineChoice()
        }

        let order = pageOrder
        guard let index = order.firstIndex(of: page), index + 1 < order.count else {
            finish()
            return
        }
        page = order[index + 1]
    }

    func goBack() {
        let order = pageOrder
        guard let index = order.firstIndex(of: page), index > 0 else { return }
        page = order[index - 1]
    }

    // MARK: - Engine choice

    /// Store the drafted key and move both engines to Mistral. The driver is
    /// cancelled rather than left alone: a user who started the local download,
    /// went back, and switched to Mistral must not keep a download running for
    /// an engine nothing will use.
    private func applyMistralEngineChoice() {
        driver.cancel()
        // A cancelled download is no download: clearing the flag re-offers
        // "Begin download" if the user comes back and picks Local again, and
        // it is `startDownloads()` that moves the engines back to managed.
        // Without this, Local → Begin download → back → Mistral → back → Local
        // → Finish reads "runs on this Mac" while both engines are still on
        // Mistral (GLM review, 2026-09-16).
        downloadsStarted = false
        viewModel.engines.applyMistralQuickSetup(apiKey: mistralAPIKeyDraft)
    }

    /// The `.engine` page's "Check key" button. Advisory only — see
    /// `mistralAPIKeyCheckState`.
    func checkMistralAPIKeyDraft() {
        guard !mistralAPIKeyCheckState.isChecking else { return }
        let apiKey = mistralAPIKeyDraft
        guard !apiKey.trimmed.isEmpty else { return }
        mistralAPIKeyCheckState = .checking
        mistralAPIKeyCheckTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let verification = await self.viewModel.engines.verifyMistralAPIKey(apiKey)
            self.mistralAPIKeyCheckState = .finished(verification)
        }
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
        viewModel.engines.applyDictationBackendModeChange(.managedLocal)
        if polishingConsent {
            viewModel.engines.applyPolishingBackendModeChange(.managedLocal)
            settings.llmPolishingEnabled = true
        }
        driver.start(dictation: true, polishing: polishingConsent)
    }

    /// The "I run my own server instead" escape hatch: point both backends at
    /// external URLs, finish onboarding, and jump the user to the Engines tab.
    func useOwnServer() {
        driver.cancel()
        // Undo any polishing opt-in from this wizard run: leaving it enabled
        // against the unconfigured default external URL would make every
        // overlay commit fire a silently failing polish request. The user
        // re-enables it once their endpoint is configured.
        settings.llmPolishingEnabled = false
        viewModel.engines.applyDictationBackendModeChange(.externalURL)
        viewModel.engines.applyPolishingBackendModeChange(.externalURL)
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

    /// One line naming the engine this run set up, so the last page confirms
    /// the choice made two pages earlier.
    var engineSummary: String {
        switch engineChoice {
        case .local:
            return "Dictation and polishing run on this Mac."
        case .mistralAPI:
            return "Dictation and polishing use Mistral's hosted models."
        }
    }
}
