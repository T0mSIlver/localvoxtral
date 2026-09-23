import ClaudeContextWire
import Foundation

extension ClaudeIntegrationSettingsModel {
    // MARK: - cmux socket

    /// Saves (or clears) the cmux socket password and forgets the typed text.
    ///
    /// Clearing on save is deliberate: the field is an input, not a display,
    /// and a secret left sitting in a SwiftUI string is one screen-share away
    /// from being read out loud. An empty or rejected value REMOVES the stored
    /// password rather than leaving the previous one quietly in force.
    func saveCmuxPassword() {
        guard let cmuxPasswords else {
            alert = DetailAlert(
                title: "Could not save the cmux password",
                detail: "The keychain is unavailable in this build."
            )
            return
        }
        let accepted = CmuxPasswordValidation.normalized(cmuxPasswordField) != nil
        let stored = cmuxPasswords.setPassword(cmuxPasswordField)
        cmuxPasswordField = ""
        hasCmuxPassword = accepted && stored
        if !stored {
            alert = DetailAlert(
                title: "Could not save the cmux password",
                detail: "The keychain refused the item. See Console for the OSStatus."
            )
            return
        }
        // A stored password says nothing about whether cmux will accept it, so
        // the socket's verdict is reset rather than assumed good: the next
        // dictation writes the real answer.
        cmuxStatus = .ok
    }
}
