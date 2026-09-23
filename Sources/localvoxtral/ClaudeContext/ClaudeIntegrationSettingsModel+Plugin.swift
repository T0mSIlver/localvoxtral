import ClaudeContextWire
import Foundation

extension ClaudeIntegrationSettingsModel {
    // MARK: - Local plugin

    public func installPlugin() async {
        await runPluginAction("Installed.") { try $0.installPlugin() }
    }

    public func updatePlugin() async {
        await runPluginAction("Updated.") { try $0.updatePlugin() }
    }

    public func uninstallPlugin() async {
        await runPluginAction("Removed.") { try $0.uninstallPlugin() }
    }

    /// The row's Repair: re-point the marketplace, leaving the installed
    /// plugin alone. Offered when the listing says the plugin is installed and
    /// loading nothing.
    public func repairMarketplaceRegistration() async {
        await runPluginAction("Repaired.") { try $0.repairMarketplaceRegistration() }
    }

    /// Keep an installed plugin LOADING, once per launch.
    ///
    /// Claude Code stores the marketplace as the directory path it was
    /// registered with and re-reads it at every session start. That path used
    /// to be inside the app bundle, so it went stale whenever the app moved —
    /// and for a `try-pr.sh` build it pointed into `/private/tmp`, which is
    /// swept. The plugin then fails to load with `cache-miss`: installed,
    /// enabled, running no hooks, in every session, until someone reinstalls
    /// it by hand (field failure, 2026-09-21).
    ///
    /// Same bargain as the launch-time update: the user chose to install the
    /// plugin, and WHERE it is loaded from is this app's business, not a
    /// decision to put in front of them. Nothing is installed or removed here
    /// — one `marketplace add`, which replaces the path and leaves the plugin,
    /// its userConfig and its cache alone.
    public func repairMarketplaceRegistrationAtLaunch() async {
        await refreshLocalPluginStatus()
        guard !isPerformingPluginAction else { return }
        let registered = await fetchMarketplaceListOutput()
            .flatMap { ClaudePluginListing.registeredMarketplacePath(in: $0) }
        guard Self.marketplaceNeedsRepair(
            status: localPluginStatus,
            registeredPath: registered,
            desiredPath: desiredMarketplacePath()
        ) else { return }
        isPerformingPluginAction = true
        defer { isPerformingPluginAction = false }

        Log.claudeContext.info("Re-pointing the Claude Code marketplace at this app's own copy")
        let service = pluginService()
        if let failure = await performAsync({ try service.repairMarketplaceRegistration() }) {
            Log.claudeContext.error(
                "Claude marketplace repair at launch failed: \(failure.describedError, privacy: .public)"
            )
        } else {
            Log.claudeContext.info("Claude Code marketplace re-pointed")
        }
        await refreshLocalPluginStatus()
    }

    /// Whether Claude Code's registration must be re-pointed. Pure, because
    /// this decides to run a command against someone's Claude Code config and
    /// every row of the table deserves a test.
    ///
    /// Two triggers, and both require an installed plugin:
    ///   - the listing says the marketplace failed to load — whatever the path
    ///     is, it is not working;
    ///   - the registered path is one that CANNOT keep working: it is already
    ///     gone, or it points inside an app bundle, which is the shape that
    ///     rots (`/private/tmp/localvoxtral-try.XXXX/…/localvoxtral.app/…`).
    ///
    /// A working path that is simply not ours is LEFT ALONE. Registering a
    /// checkout — `claude plugin marketplace add ./integrations/claude-code` —
    /// is documented in the plugin README and is how anyone edits the shim and
    /// sees the edit; taking it over at every launch would undo a deliberate
    /// setup, silently, and leave one log line to explain it (review,
    /// 2026-09-21).
    ///
    /// A path we could not read is not a path that disagrees: absence of
    /// evidence never triggers a command here.
    public nonisolated static func marketplaceNeedsRepair(
        status: ClaudePluginStatus,
        registeredPath: String?,
        desiredPath: String?,
        registrationCanRot: (String) -> Bool = { registrationCanRot(path: $0) }
    ) -> Bool {
        switch status {
        case .notInstalled, .unknown:
            return false
        case .failedToLoad:
            return true
        case .installed, .updateAvailable:
            guard let registeredPath, let desiredPath else { return false }
            guard !pathsAreTheSameDirectory(registeredPath, desiredPath) else { return false }
            return registrationCanRot(registeredPath)
        }
    }

    /// Whether a registered marketplace path is one this app must take over.
    ///
    /// The two rot shapes, and nothing else: a path that no longer exists
    /// (the sweep already happened), and a path inside an app bundle (the
    /// sweep, the move or the delete has not happened YET — an app bundle is
    /// exactly what the user drags to the Trash or replaces on update).
    public nonisolated static func registrationCanRot(
        path: String,
        directoryExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> Bool {
        guard directoryExists(path) else { return true }
        return path.contains(".app/Contents/")
    }

    /// `/tmp/x` and `/private/tmp/x` are one directory on macOS, and a
    /// registration that names either must not read as a disagreement.
    nonisolated static func pathsAreTheSameDirectory(_ lhs: String, _ rhs: String) -> Bool {
        func normalized(_ path: String) -> String {
            URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
        }
        return normalized(lhs) == normalized(rhs)
    }

    /// Bring an installed plugin up to the bundled version, once per launch.
    ///
    /// The user chose to install the plugin; keeping it at the version this
    /// app ships is part of that choice, so it needs no click. A plugin that
    /// is not installed stays that way. The update never uninstalls, so a
    /// failure leaves the old plugin working; it is logged and left to the
    /// row, which still offers Update. An alert nobody asked for at launch
    /// would be worse than a row that says what happened.
    public func updateOutdatedPluginAtLaunch() async {
        await refreshLocalPluginStatus()
        guard case .updateAvailable(let installed, let bundled) = localPluginStatus,
              !isPerformingPluginAction
        else { return }
        isPerformingPluginAction = true
        defer { isPerformingPluginAction = false }

        Log.claudeContext.info(
            "Updating the Claude Code plugin from \(installed, privacy: .public) to \(bundled, privacy: .public)"
        )
        let service = pluginService()
        if let failure = await performAsync({ try service.updateInstalledPlugin() }) {
            Log.claudeContext.error(
                "Claude plugin update at launch failed: \(failure.describedError, privacy: .public)"
            )
        } else {
            Log.claudeContext.info("Claude Code plugin updated to \(bundled, privacy: .public)")
        }
        await refreshLocalPluginStatus()
    }

    /// The Vibe counterpart of `updateOutdatedPluginAtLaunch`, under the same
    /// rule: only an install the user already made, and only when BOTH halves
    /// are present and one differs from this build. A partial or unreadable
    /// install is a state the user has to look at, so it waits for Set up.
    public func updateOutdatedVibeHooksAtLaunch() async {
        guard let service = vibeService(), !isPerformingVibeAction else { return }
        refreshVibeStatus()
        guard vibeStatus == .updateAvailable else { return }
        isPerformingVibeAction = true
        defer { isPerformingVibeAction = false }

        Log.claudeContext.info("Updating the Mistral Vibe hooks to this build's")
        if let failure = await performAsync({ try service.install() }) {
            Log.claudeContext.error(
                "Vibe hooks update at launch failed: \(failure.describedError, privacy: .public)"
            )
        } else {
            Log.claudeContext.info("Mistral Vibe hooks updated")
        }
        refreshVibeStatus()
    }

    private func runPluginAction(
        _ successCopy: String,
        _ body: @escaping @Sendable (any ClaudePluginInstalling) throws -> Void
    ) async {
        guard !isPerformingPluginAction else { return }
        isPerformingPluginAction = true
        pluginResult = nil
        defer { isPerformingPluginAction = false }

        let service = pluginService()
        guard let failure = await performAsync({ try body(service) }) else {
            pluginResult = successCopy
            await refreshLocalPluginStatus()
            return
        }
        // Short line in the pane; the CLI's actual output — which can be pages of
        // it — goes to the alert and the log only.
        pluginResult = Self.shortPluginFailure(failure)
        alert = DetailAlert(
            title: "Claude Code plugin",
            detail: Self.pluginFailureDetail(failure)
        )
        Log.claudeContext.error(
            "Claude plugin action failed: \(failure.describedError, privacy: .public)"
        )
        await refreshLocalPluginStatus()
    }

    /// Re-probe `claude plugin list` after an action (or with the pane's
    /// refresh) so the row's sentence describes the new state.
    public func refreshLocalPluginStatus() async {
        let output = await fetchPluginListOutput()
        localPluginStatus = ClaudePluginStatus.derive(
            listOutput: output, bundledVersion: bundledPluginVersion
        )
    }

    /// One short sentence, never the CLI's output.
    static func shortPluginFailure(_ failure: ClaudePluginActionFailure) -> String {
        switch failure.serviceError {
        case .claudeCLINotFound: return "Claude Code CLI not found."
        case .marketplaceUnavailable: return "Plugin files missing from the app."
        case .commandTimedOut: return "Claude Code did not respond."
        case .outputTooLarge: return "Claude Code produced too much output."
        case .commandFailed, .none: return "Claude Code reported an error."
        }
    }

    static func pluginFailureDetail(_ failure: ClaudePluginActionFailure) -> String {
        switch failure.serviceError {
        case .claudeCLINotFound:
            return "localvoxtral could not find the `claude` command. Install Claude Code, or make sure "
                + "`claude` is on the PATH that GUI apps see."
        case .marketplaceUnavailable:
            return "The bundled plugin files are missing from this build of localvoxtral. Reinstall the app."
        case .commandTimedOut(_, _, let seconds):
            return "`claude plugin` did not finish within \(Int(seconds))s and was stopped."
        case .outputTooLarge(_, let capBytes):
            return "`claude plugin` produced more than \(capBytes / 1024) KB of output and was stopped."
        case .commandFailed(_, let exitCode, let message):
            return "`claude plugin` exited with code \(exitCode).\n\n\(message)"
        case .none:
            return failure.describedError
        }
    }
}
