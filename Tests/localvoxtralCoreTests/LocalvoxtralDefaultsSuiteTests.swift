import Foundation
import XCTest
import localvoxtralCore

/// `LOCALVOXTRAL_DEFAULTS_SUITE` moves the app's preferences into a suite of
/// their own, and a name the system will not open is refused rather than
/// replaced by the app's own domain (#1029).
final class LocalvoxtralDefaultsSuiteTests: XCTestCase {
    private let bundleIdentifier = "com.localvoxtral.app"

    func testUnsetOrEmptyUsesTheAppsOwnDomain() {
        for environment in [[:], [LocalvoxtralDefaultsSuite.environmentKey: ""]] {
            guard case .standard = LocalvoxtralDefaultsSuite.resolve(
                environment: environment, bundleIdentifier: bundleIdentifier
            ) else { return XCTFail("\(environment) did not resolve to the standard domain") }
        }
    }

    func testASuiteKeepsItsWritesOutOfTheStandardDomain() throws {
        let name = "com.localvoxtral.harness-test-\(UUID().uuidString)"
        let key = "settings.lvx_defaults_suite_test_\(UUID().uuidString)"
        guard case .suite(let resolvedName, let defaults) = LocalvoxtralDefaultsSuite.resolve(
            environment: [LocalvoxtralDefaultsSuite.environmentKey: name],
            bundleIdentifier: bundleIdentifier
        ) else { return XCTFail("\(name) was not opened as a suite") }
        defer { defaults.removePersistentDomain(forName: name) }

        defaults.set("external_url", forKey: key)

        XCTAssertEqual(resolvedName, name)
        XCTAssertEqual(UserDefaults(suiteName: name)?.string(forKey: key), "external_url")
        XCTAssertNil(UserDefaults.standard.object(forKey: key))
    }

    func testTheAppsOwnDomainAndTheGlobalDomainAreRefused() {
        for name in [bundleIdentifier, UserDefaults.globalDomain] {
            guard case .refused(let refused) = LocalvoxtralDefaultsSuite.resolve(
                environment: [LocalvoxtralDefaultsSuite.environmentKey: name],
                bundleIdentifier: bundleIdentifier
            ) else { return XCTFail("\(name) was not refused") }
            XCTAssertEqual(refused, name)
        }
    }
}
