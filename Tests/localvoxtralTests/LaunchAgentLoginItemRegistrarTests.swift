import Foundation
import XCTest

@testable import localvoxtral

/// The launch agent behind "Open localvoxtral at login" (#449), against real
/// files in a temporary directory — never `~/Library/LaunchAgents`, which on
/// this machine belongs to the developer.
@MainActor
final class LaunchAgentLoginItemRegistrarTests: XCTestCase {
    private var directory: URL!
    private let appBundle = URL(filePath: "/Applications/localvoxtral.app")
    /// How many times registering asked for a user disablement to be cleared.
    /// A test must never run the real `launchctl`, which would change the
    /// launchd state of the machine running the suite.
    private var disablementClears = 0

    override func setUp() async throws {
        try await super.setUp()
        directory = URL(filePath: NSTemporaryDirectory())
            .appending(path: "localvoxtral-launch-agents-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
        directory = nil
        try await super.tearDown()
    }

    private func makeRegistrar() -> LaunchAgentLoginItemRegistrar {
        makeRegistrar(appBundle: appBundle)
    }

    private func makeRegistrar(appBundle: URL?) -> LaunchAgentLoginItemRegistrar {
        LaunchAgentLoginItemRegistrar(
            directory: directory,
            appBundle: appBundle,
            clearDisablement: { self.disablementClears += 1 }
        )
    }

    private var plistURL: URL {
        directory.appending(path: "\(LaunchAgentLoginItemRegistrar.label).plist")
    }

    private func installedAgent() throws -> [String: Any] {
        let data = try Data(contentsOf: plistURL)
        let plist = try PropertyListSerialization.propertyList(
            from: data, options: [], format: nil)
        return try XCTUnwrap(plist as? [String: Any])
    }

    /// Turning it on has to survive the user having turned it off in System
    /// Settings, which disables the label in launchd rather than deleting the
    /// file — the file alone would then say on while login skipped it.
    func testRegisteringAlsoClearsAUserDisablement() throws {
        try makeRegistrar().register()

        XCTAssertEqual(disablementClears, 1)
    }

    /// A login item naming a copy that is gone opens nothing: the row reads
    /// off, and turning it on re-points the agent at this app.
    func testAnAgentNamingAMissingCopyReadsAsOff() throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        let agent: [String: Any] = [
            "Label": LaunchAgentLoginItemRegistrar.label,
            "ProgramArguments": ["/usr/bin/open", "/private/tmp/deleted-by-the-reaper.app"],
            "RunAtLoad": true,
        ]
        try PropertyListSerialization
            .data(fromPropertyList: agent, format: .xml, options: 0)
            .write(to: plistURL)

        XCTAssertEqual(makeRegistrar().currentState(), .disabled)
    }

    /// An app run from where it was unzipped is translocated onto a mount that
    /// dies with the process, so there is nothing durable to open at login.
    func testATranslocatedCopyHasNothingToOpenAtLogin() {
        let translocated = URL(
            filePath:
                "/private/var/folders/x/AppTranslocation/0F1E-2D3C/d/localvoxtral.app")
        let registrar = makeRegistrar(appBundle: translocated)

        XCTAssertEqual(registrar.currentState(), .unavailable)
    }

    func testNothingInstalledReadsAsOff() {
        XCTAssertEqual(makeRegistrar().currentState(), .disabled)
    }

    /// The agent has to say three things for launchd to open the app at the
    /// next login, and nothing else matters: its label, what to run, and that
    /// it runs at load.
    func testRegisteringWritesAnAgentThatOpensThisApp() throws {
        let registrar = makeRegistrar()

        try registrar.register()

        let agent = try installedAgent()
        XCTAssertEqual(agent["Label"] as? String, LaunchAgentLoginItemRegistrar.label)
        XCTAssertEqual(
            agent["ProgramArguments"] as? [String],
            ["/usr/bin/open", "/Applications/localvoxtral.app"]
        )
        XCTAssertEqual(agent["RunAtLoad"] as? Bool, true)
        XCTAssertEqual(registrar.currentState(), .enabled)
    }

    /// The directory does not exist on a Mac that has never had a launch
    /// agent, which is most of them.
    func testRegisteringCreatesTheDirectory() throws {
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))

        try makeRegistrar().register()

        XCTAssertTrue(FileManager.default.fileExists(atPath: plistURL.path))
    }

    func testUnregisteringRemovesTheAgent() throws {
        let registrar = makeRegistrar()
        try registrar.register()

        try registrar.unregister()

        XCTAssertFalse(FileManager.default.fileExists(atPath: plistURL.path))
        XCTAssertEqual(registrar.currentState(), .disabled)
    }

    /// Turning off what is already off is not an error — the user may have
    /// removed it in System Settings since the pane last read it.
    func testUnregisteringWhatIsNotThereIsNotAnError() throws {
        XCTAssertNoThrow(try makeRegistrar().unregister())
    }

    /// The everyday state on the owner's Mac: the login item names the
    /// installed copy while a build under test is the one asking.
    func testAnAgentForAnotherCopyReadsAsOnAndIsNamedAsSuch() throws {
        // The registered copy has to exist for the state to mean anything, so
        // it is this directory standing in for an installed bundle.
        let installed = directory.appending(path: "installed-localvoxtral.app")
        try FileManager.default.createDirectory(
            at: installed, withIntermediateDirectories: true)
        try makeRegistrar(appBundle: installed).register()

        let underTest = makeRegistrar(
            appBundle: URL(filePath: "/private/tmp/localvoxtral-try.1/localvoxtral.app"))

        XCTAssertEqual(underTest.currentState(), .enabledForAnotherCopy)
    }

    /// Turning it on from a second copy takes the login item over rather than
    /// leaving two of them: there is one file, and it names one app.
    func testRegisteringFromAnotherCopyTakesOverTheSameAgent() throws {
        let installed = directory.appending(path: "installed-localvoxtral.app")
        try FileManager.default.createDirectory(
            at: installed, withIntermediateDirectories: true)
        try makeRegistrar(appBundle: installed).register()
        let other = URL(filePath: "/private/tmp/localvoxtral-try.1/localvoxtral.app")

        let underTest = makeRegistrar(appBundle: other)
        try underTest.register()

        XCTAssertEqual(underTest.currentState(), .enabled)
        XCTAssertEqual(
            try installedAgent()["ProgramArguments"] as? [String],
            ["/usr/bin/open", other.path]
        )
    }

    func testAnUnbundledBuildHasNothingToOpenAtLogin() {
        let registrar = makeRegistrar(appBundle: nil)

        XCTAssertEqual(registrar.currentState(), .unavailable)
        XCTAssertThrowsError(try registrar.register())
    }

    /// A file that is not our plist is not read as a login item: the switch
    /// reads off, and turning it on overwrites it.
    func testAFileThatIsNotOurAgentReadsAsOff() throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        try Data("not a plist".utf8).write(to: plistURL)

        XCTAssertEqual(makeRegistrar().currentState(), .disabled)
        XCTAssertNoThrow(try makeRegistrar().register())
        XCTAssertEqual(makeRegistrar().currentState(), .enabled)
    }
}
