import Foundation
import Synchronization
import XCTest
@testable import localvoxtral

/// An in-memory stand-in for the login keychain.
///
/// The real backend is never exercised here on purpose: a unit suite that
/// writes keychain items either prompts the developer running it or silently
/// mutates their machine's secrets, and CI would inherit both problems.
private final class FakeCmuxKeychain: CmuxKeychainBackend, @unchecked Sendable {
    private struct Key: Hashable {
        var service: String
        var account: String
    }

    private let items = Mutex<[Key: Data]>([:])
    private let writesFail: Bool

    init(writesFail: Bool = false) {
        self.writesFail = writesFail
    }

    var storedItemCount: Int { items.withLock { $0.count } }

    func read(service: String, account: String) -> Data? {
        items.withLock { $0[Key(service: service, account: account)] }
    }

    func write(_ data: Data, service: String, account: String) -> Bool {
        guard !writesFail else { return false }
        items.withLock { $0[Key(service: service, account: account)] = data }
        return true
    }

    func delete(service: String, account: String) -> Bool {
        items.withLock { _ = $0.removeValue(forKey: Key(service: service, account: account)) }
        return true
    }
}

final class CmuxSocketPasswordStoreTests: XCTestCase {
    private func makeStore(
        backend: FakeCmuxKeychain
    ) -> CmuxSocketPasswordStore {
        CmuxSocketPasswordStore(
            service: "test.localvoxtral.cmux",
            account: "test-account",
            backend: backend
        )
    }

    func testStoredPasswordRoundTrips() {
        let backend = FakeCmuxKeychain()
        let store = makeStore(backend: backend)

        XCTAssertNil(store.password(), "nothing stored yet")
        XCTAssertTrue(store.setPassword("hunter2"))
        XCTAssertEqual(store.password(), "hunter2")
    }

    func testSavingOverwritesRatherThanAccumulating() {
        let backend = FakeCmuxKeychain()
        let store = makeStore(backend: backend)

        store.setPassword("first")
        store.setPassword("second")

        XCTAssertEqual(store.password(), "second")
        XCTAssertEqual(backend.storedItemCount, 1)
    }

    /// cmux compares against a value it trimmed of surrounding whitespace, so a
    /// password we stored untrimmed would be rejected by a server that has the
    /// "same" one.
    func testSurroundingWhitespaceIsTrimmedBeforeStoring() {
        let backend = FakeCmuxKeychain()
        let store = makeStore(backend: backend)

        store.setPassword("  hunter2\n")

        XCTAssertEqual(store.password(), "hunter2")
    }

    func testInnerSpacesSurvive() {
        let backend = FakeCmuxKeychain()
        let store = makeStore(backend: backend)

        store.setPassword("correct horse battery staple")

        XCTAssertEqual(store.password(), "correct horse battery staple")
    }

    func testEmptyOrWhitespaceOnlyRemovesTheStoredPassword() {
        let backend = FakeCmuxKeychain()
        let store = makeStore(backend: backend)
        store.setPassword("hunter2")

        store.setPassword("   ")

        XCTAssertNil(store.password())
        XCTAssertEqual(backend.storedItemCount, 0, "a cleared field means stop using a password")
    }

    func testNilRemovesTheStoredPassword() {
        let backend = FakeCmuxKeychain()
        let store = makeStore(backend: backend)
        store.setPassword("hunter2")

        store.setPassword(nil)

        XCTAssertNil(store.password())
    }

    /// A rejected value must not leave the PREVIOUS password quietly in force:
    /// the user would then believe they had changed it.
    func testARejectedValueRemovesRatherThanKeepingTheOldOne() {
        let backend = FakeCmuxKeychain()
        let store = makeStore(backend: backend)
        store.setPassword("hunter2")

        store.setPassword("two\nlines")

        XCTAssertNil(store.password())
        XCTAssertEqual(backend.storedItemCount, 0)
    }

    func testOversizedValuesAreRejected() {
        let backend = FakeCmuxKeychain()
        let store = makeStore(backend: backend)

        let tooLong = String(repeating: "a", count: CmuxPasswordValidation.maxPasswordBytes + 1)
        XCTAssertNil(CmuxPasswordValidation.normalized(tooLong))
        store.setPassword(tooLong)

        XCTAssertNil(store.password())
    }

    func testExactlyTheMaximumLengthIsAccepted() {
        let backend = FakeCmuxKeychain()
        let store = makeStore(backend: backend)

        let atLimit = String(repeating: "a", count: CmuxPasswordValidation.maxPasswordBytes)
        XCTAssertTrue(store.setPassword(atLimit))
        XCTAssertEqual(store.password(), atLimit)
    }

    func testControlCharactersAreRejected() {
        XCTAssertNil(CmuxPasswordValidation.normalized("hunter\u{0}2"))
        XCTAssertNil(CmuxPasswordValidation.normalized("hunter\u{1B}2"))
        XCTAssertNil(CmuxPasswordValidation.normalized("hunter\r2"))
    }

    func testAKeychainWriteFailureIsReported() {
        let backend = FakeCmuxKeychain(writesFail: true)
        let store = makeStore(backend: backend)

        XCTAssertFalse(store.setPassword("hunter2"))
        XCTAssertNil(store.password())
    }

    /// A value someone put in the keychain by hand is not this build's input.
    func testAStoredValueIsRevalidatedOnRead() {
        let backend = FakeCmuxKeychain()
        _ = backend.write(
            Data("bad\nvalue".utf8), service: "test.localvoxtral.cmux", account: "test-account"
        )
        let store = makeStore(backend: backend)

        XCTAssertNil(store.password())
    }
}

/// The Settings row's half: what the model does with the typed field.
@MainActor
final class CmuxPasswordSettingsRowTests: XCTestCase {
    private final class RecordingPasswordStore: CmuxPasswordStoring, @unchecked Sendable {
        private let value = Mutex<String?>(nil)
        private let succeed: Bool

        init(initial: String? = nil, succeed: Bool = true) {
            self.succeed = succeed
            value.withLock { $0 = initial }
        }

        func password() -> String? { value.withLock { $0 } }

        func setPassword(_ password: String?) -> Bool {
            guard succeed else { return false }
            value.withLock { $0 = CmuxPasswordValidation.normalized(password) }
            return true
        }
    }

    /// The cmux row does not touch the plugin surface; this exists only so the
    /// model can be built.
    private struct InertPluginService: ClaudePluginInstalling {
        func installPlugin() throws {}
        func updatePlugin() throws {}
        func uninstallPlugin() throws {}
    }

    private func makeModel(
        passwords: (any CmuxPasswordStoring)?
    ) -> ClaudeIntegrationSettingsModel {
        ClaudeIntegrationSettingsModel(
            registry: nil,
            listener: nil,
            pluginService: { InertPluginService() },
            performAsync: { body in
                do {
                    try body()
                    return nil
                } catch {
                    return ClaudePluginActionFailure(error)
                }
            },
            cmuxPasswords: passwords
        )
    }

    func testSavingStoresThePasswordAndForgetsTheTypedText() {
        let store = RecordingPasswordStore()
        let model = makeModel(passwords: store)

        model.cmuxPasswordField = "hunter2"
        model.saveCmuxPassword()

        XCTAssertEqual(store.password(), "hunter2")
        XCTAssertEqual(
            model.cmuxPasswordField, "",
            "a secret must not sit in a SwiftUI string after it has been stored"
        )
        XCTAssertTrue(model.hasCmuxPassword)
        XCTAssertEqual(model.cmuxStatusText, "Password saved.")
    }

    func testAnExistingPasswordIsReportedButNeverShownBack() {
        let model = makeModel(passwords: RecordingPasswordStore(initial: "hunter2"))

        XCTAssertTrue(model.hasCmuxPassword)
        XCTAssertEqual(model.cmuxPasswordField, "")
    }

    func testClearingTheFieldRemovesTheStoredPassword() {
        let store = RecordingPasswordStore(initial: "hunter2")
        let model = makeModel(passwords: store)

        model.cmuxPasswordField = ""
        model.saveCmuxPassword()

        XCTAssertNil(store.password())
        XCTAssertFalse(model.hasCmuxPassword)
        XCTAssertEqual(model.cmuxStatusText, "No password saved.")
    }

    func testTheSocketVerdictOutranksTheSetupState() {
        let model = makeModel(passwords: RecordingPasswordStore(initial: "hunter2"))

        model.cmuxStatus = .authenticationRequired

        XCTAssertEqual(model.cmuxStatusText, "cmux socket requires password mode.")
    }

    func testAKeychainFailureIsSurfacedAsAnAlertNotASilentNoOp() {
        let model = makeModel(passwords: RecordingPasswordStore(succeed: false))

        model.cmuxPasswordField = "hunter2"
        model.saveCmuxPassword()

        XCTAssertNotNil(model.alert)
        XCTAssertFalse(model.hasCmuxPassword)
    }

    func testNoKeychainMeansTheRowSaysSoRatherThanPretending() {
        let model = makeModel(passwords: nil)

        model.cmuxPasswordField = "hunter2"
        model.saveCmuxPassword()

        XCTAssertNotNil(model.alert)
        XCTAssertFalse(model.hasCmuxPassword)
    }
}
