import ClaudeContextWire
import Foundation

extension ClaudeIntegrationSettingsModel {
    // MARK: - Saved herdr machines

    /// Import one saved herdr machine: pre-fill the enrollment form with the
    /// profile's target and label, then run the SAME consent-gated enrollment
    /// the typed form runs. Nothing about enrollment itself changes — the
    /// sheet, its Set Up consent, and every step after it are the typed form's.
    public func importHerdrMachine(_ candidate: HerdrMachineImportCandidate) async {
        // No re-entrancy: a second tap while the sheet is up (or an action is
        // running) must not enroll again — `enroll()` has no duplicate-alias
        // check, so two passing calls would create two hosts on one alias.
        guard presentedPlan == nil && !isEnrollmentBusy else { return }
        // The snapshot's own status may predate a hand enrollment of the same
        // alias, so it is only a fast path: freshness is re-derived below
        // from a new catalog read and the current registry.
        guard candidate.status == .importable else { return }
        let enrolledHosts = registry?.hosts() ?? []
        guard case .catalog(let catalog) = herdrMachineCatalogReading(),
              catalog.profiles.contains(where: { $0.id == candidate.profile.id }),
              Self.herdrMachineStatus(profile: candidate.profile, enrolledHosts: enrolledHosts)
                  == .importable
        else { return }
        enrollLabel = candidate.profile.label
        enrollSSHAlias = candidate.profile.target
        await enroll()
    }

    /// Derives the Saved-herdr-machines section from one catalog reading.
    /// Candidates keep the catalog's file order.
    static func herdrMachineSection(
        reading: HerdrMachineCatalogReading,
        enrolledHosts: [ClaudeRemoteHost]
    ) -> HerdrMachineImportSection {
        switch reading {
        case .absent:
            return .absent
        case .unreadable:
            return .unreadable
        case .catalog(let catalog):
            // Zero profiles is "no machines saved", not a header with zero
            // rows: an empty catalog renders nothing, like an absent one.
            guard !catalog.profiles.isEmpty else { return .absent }
            return .candidates(
                catalog.profiles.map { profile in
                    HerdrMachineImportCandidate(
                        profile: profile,
                        status: herdrMachineStatus(profile: profile, enrolledHosts: enrolledHosts)
                    )
                }
            )
        }
    }

    /// One saved machine's status against the enrolled hosts.
    static func herdrMachineStatus(
        profile: HerdrMachineProfile,
        enrolledHosts: [ClaudeRemoteHost]
    ) -> HerdrMachineImportStatus {
        // EXACT match only. Settings never canonicalizes a target with
        // `ssh -G`: that comparison belongs to the join arm, at join time,
        // where its cost and its failures are accounted for. Here a target
        // that merely RESOLVES to the same (hostname, port) as an enrolled
        // alias is not that alias, and saying so would hide an Import the
        // user needs.
        if let enrolled = enrolledHosts.first(where: {
            !$0.isRevoked && $0.sshHostAlias == profile.target
        }) {
            return .enrolled(hostID: enrolled.id)
        }
        // Deliberate precedence: herdr's own off switch wins over the
        // alias-shape check, so a disabled non-alias target renders dimmed
        // with no sentence rather than an instruction it cannot act on.
        guard profile.enabled else { return .disabled }
        return ClaudeRemoteEnrollmentService.isValidHostAlias(profile.target) ? .importable : .needsAlias
    }
}
