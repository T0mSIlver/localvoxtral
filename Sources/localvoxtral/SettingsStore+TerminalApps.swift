import Foundation

extension SettingsStore {
    func persistUserTerminalApps() {
        guard let data = try? JSONEncoder().encode(userTerminalApps) else { return }
        defaults.set(data, forKey: Keys.userTerminalApps)
    }

    /// Appends a user-added terminal app and forgets any recorded removal of
    /// its id: re-adding is a fresh start for the migration ledger.
    func addUserTerminalApp(_ app: UserTerminalApp) {
        userTerminalApps.append(app)
        var removed = removedUserTerminalAppBundleIDs()
        guard removed.contains(app.bundleID) else { return }
        removed.removeAll { $0 == app.bundleID }
        defaults.set(removed, forKey: UserTerminalAppsMigrator.removedBundleIDsKey)
    }

    /// Removes a user-added terminal app and records the removal in the
    /// migration ledger (`UserTerminalAppsMigrator.removedBundleIDsKey`), so
    /// the launch-time `terminal_apps.toml` import cannot resurrect the id
    /// even if the imported-ids ledger is lost.
    func removeUserTerminalApp(bundleID: String) {
        userTerminalApps.removeAll { $0.bundleID == bundleID }
        var removed = removedUserTerminalAppBundleIDs()
        guard !removed.contains(bundleID) else { return }
        removed.append(bundleID)
        defaults.set(removed, forKey: UserTerminalAppsMigrator.removedBundleIDsKey)
    }

    private func removedUserTerminalAppBundleIDs() -> [String] {
        defaults.stringArray(forKey: UserTerminalAppsMigrator.removedBundleIDsKey) ?? []
    }

    static func loadUserTerminalApps(from defaults: UserDefaults) -> [UserTerminalApp] {
        guard let data = defaults.data(forKey: Keys.userTerminalApps) else { return [] }
        do {
            return try JSONDecoder().decode([UserTerminalApp].self, from: data)
        } catch {
            // The failure, never the payload: this line must not become the
            // place a corrupt blob's contents reach the log.
            Log.persistence.error(
                "Stored user terminal apps are unreadable; starting from an empty list. \(error.localizedDescription, privacy: .public)"
            )
            return []
        }
    }
}
