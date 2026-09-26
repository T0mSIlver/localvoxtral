import Foundation

extension SettingsStore {
    // MARK: - API keys (login Keychain)

    /// Engines-pane copy for a secret store that refused. One short sentence
    /// each: Settings shows the summary, the `Secrets` log carries the OSStatus.
    static let secretStoreReadFailureSummary =
        "Keychain unavailable; API keys could not be read."
    static let secretStoreWriteFailureSummary =
        "Keychain unavailable; the API key was not saved."

    /// Where each secret used to live in UserDefaults. Read ONLY by the
    /// one-time migration below — nothing else may touch these keys again.
    private static func legacyDefaultsKey(for key: SecretKey) -> String {
        switch key {
        case .realtimeAPIKey: return Keys.apiKey
        case .llmPolishingAPIKey: return Keys.llmPolishingAPIKey
        case .mistralAPIKey: return Keys.mistralAPIKey
        // Never stored in UserDefaults; the name only has to be unused.
        case .jevAPIKey: return Keys.jevAPIKeyNeverStored
        }
    }

    /// What the migration sweep learned, plus the sentence the UI must show
    /// when something refused.
    struct ResolvedSecrets {
        var values: [SecretKey: String] = [:]
        var failureSummary: String?
    }

    /// Migrates any plist-era keys into the secret store, once per install.
    ///
    /// Returns only what the sweep itself learned — a value it migrated, or one
    /// it could not migrate and left in the plist. Every other key is read
    /// later and on demand (`ensureSecretsLoaded`): each read of a stored item
    /// can cost the user a modal keychain prompt, so launch must not pay for
    /// engines the user has not selected.
    ///
    /// Two rules make the sweep safe to run on a half-migrated install:
    /// - a plist value is only written when the store has nothing, so a stale
    ///   copy can never clobber a newer key;
    /// - a failed write leaves the plist value alone and keeps using it for
    ///   this process, because losing a user's API key is worse than leaving a
    ///   copy of it where it already was.
    static func migrateLegacySecrets(
        defaults: UserDefaults,
        secretStore: any SecretStoring
    ) -> ResolvedSecrets {
        var resolved = ResolvedSecrets()
        var strandedInDefaults: [SecretKey: String] = [:]

        if !defaults.bool(forKey: Keys.apiKeysMigratedToKeychain) {
            var sweptEverything = true
            for key in SecretKey.allCases {
                let defaultsKey = legacyDefaultsKey(for: key)
                guard
                    let legacy = defaults.string(forKey: defaultsKey)?.trimmed,
                    !legacy.isEmpty
                else {
                    // Nothing worth keeping; drop any blank leftover so the
                    // plist stops carrying these keys at all.
                    defaults.removeObject(forKey: defaultsKey)
                    continue
                }

                do {
                    let existing = try secretStore.secret(for: key) ?? ""
                    if existing.isEmpty {
                        try secretStore.setSecret(legacy, for: key)
                        resolved.values[key] = legacy
                    } else {
                        // A newer key is already stored; the plist copy is
                        // stale, and the store still wins.
                        resolved.values[key] = existing
                    }
                    defaults.removeObject(forKey: defaultsKey)
                    Log.secrets.notice(
                        "Migrated \(key.rawValue, privacy: .public) from UserDefaults into the keychain"
                    )
                } catch {
                    sweptEverything = false
                    strandedInDefaults[key] = legacy
                    resolved.failureSummary = Self.secretStoreWriteFailureSummary
                    Log.secrets.error(
                        "Keychain migration of \(key.rawValue, privacy: .public) failed; the UserDefaults copy stays in place and is used for this launch: \(String(describing: error), privacy: .public)"
                    )
                }
            }
            if sweptEverything {
                defaults.set(true, forKey: Keys.apiKeysMigratedToKeychain)
            }
        }

        // A key the store refused stays on the plist copy for this launch, and
        // that copy is the value this process runs with.
        for (key, stranded) in strandedInDefaults {
            resolved.values[key] = stranded
        }

        return resolved
    }

    /// Reads `keys` out of the secret store, at most once each per process, and
    /// publishes what it finds on the matching property.
    ///
    /// Why this is not done at launch for all three: the app has no Team ID, so
    /// macOS partitions its keychain items by the build's code-signing hash and
    /// the first read from a newly installed build raises a modal prompt. A
    /// user who dictates locally should never see one, so a key is fetched only
    /// when something can actually use it — the engines selected at launch, an
    /// engine switched on later, and the Settings window when it opens to show
    /// the field.
    ///
    /// A key whose store read fails or comes back empty keeps whatever the
    /// environment resolved at init; the store is authoritative only when it
    /// answers with a value.
    func ensureSecretsLoaded(_ keys: Set<SecretKey>) {
        for key in SecretKey.allCases where keys.contains(key) {
            loadSecretIfNeeded(key)
        }
    }

    /// Every key, for the places that display or report all three: the Settings
    /// window and the diagnostics export.
    func ensureAllSecretsLoaded() {
        ensureSecretsLoaded(Set(SecretKey.allCases))
    }

    /// The secrets the current configuration can actually use. Managed local
    /// engines authenticate with nothing, so the common setup needs no key at
    /// all.
    static func secretsInUse(
        dictationMode: BackendMode,
        polishingMode: BackendMode,
        polishingEnabled: Bool
    ) -> Set<SecretKey> {
        var keys: Set<SecretKey> = []
        switch dictationMode {
        case .managedLocal: break
        case .externalURL: keys.insert(.realtimeAPIKey)
        case .mistralAPI: keys.insert(.mistralAPIKey)
        }
        guard polishingEnabled else { return keys }
        switch polishingMode {
        case .managedLocal: break
        case .externalURL: keys.insert(.llmPolishingAPIKey)
        case .mistralAPI: keys.insert(.mistralAPIKey)
        }
        return keys
    }

    /// Loads whatever the engines currently selected need. Called at the end of
    /// init and whenever one of those selections changes.
    func ensureSecretsForSelectedEnginesLoaded() {
        ensureSecretsLoaded(
            Self.secretsInUse(
                dictationMode: dictationBackendMode,
                polishingMode: polishingBackendMode,
                polishingEnabled: llmPolishingEnabled
            )
        )
    }

    private func loadSecretIfNeeded(_ key: SecretKey) {
        guard !loadedSecretKeys.contains(key) else { return }
        // Inserted before the read, not after: a read that throws must not be
        // retried on every mode change and every Settings open — one prompt is
        // the budget.
        loadedSecretKeys.insert(key)

        let stored: String
        do {
            stored = try secretStore.secret(for: key) ?? ""
        } catch {
            secretStoreFailureSummary = Self.secretStoreReadFailureSummary
            Log.secrets.error(
                "Reading \(key.rawValue, privacy: .public) from the keychain failed; it reads as unset for this launch: \(String(describing: error), privacy: .public)"
            )
            return
        }
        guard !stored.isEmpty else { return }

        // The write-through in these properties' `didSet` would store the value
        // that just came out of the store — another keychain operation, and
        // another chance to prompt.
        isApplyingStoredSecret = true
        defer { isApplyingStoredSecret = false }
        switch key {
        case .realtimeAPIKey: apiKey = stored
        case .llmPolishingAPIKey: llmPolishingAPIKey = stored
        case .mistralAPIKey: mistralAPIKey = stored
        case .jevAPIKey: jevAPIKey = stored
        }
    }

    /// The precedence `loadString` gave these keys, with the secret store
    /// standing in for the plist: a stored key wins, then the env override,
    /// then empty. An env value is never written back — it belongs to the
    /// process that exported it, not to the user's keychain.
    static func resolveSecret(
        _ secrets: ResolvedSecrets,
        _ key: SecretKey,
        envKey: String,
        environment: [String: String]
    ) -> String {
        let stored = secrets.values[key] ?? ""
        guard stored.isEmpty else { return stored }
        return environment[envKey] ?? ""
    }

    /// Write-through for the three key properties. Trimmed, because a pasted
    /// key routinely carries a trailing newline the wire never wants; empty
    /// deletes the item rather than storing a blank.
    func persistSecret(_ value: String, for key: SecretKey) {
        // A value the store just handed us is not a change to write back.
        guard !isApplyingStoredSecret else { return }
        // Marked loaded either way. On success the store holds exactly this
        // value, so there is nothing to fetch. On failure the value is still
        // the one this process runs with ("works this session but is not
        // saved"), and a later fetch would overwrite what the user just typed
        // with the stale stored key.
        loadedSecretKeys.insert(key)
        do {
            try secretStore.setSecret(value.trimmed, for: key)
        } catch {
            secretStoreFailureSummary = Self.secretStoreWriteFailureSummary
            Log.secrets.error(
                "Storing \(key.rawValue, privacy: .public) in the keychain failed: \(String(describing: error), privacy: .public)"
            )
        }
    }
}
