import Foundation
import XCTest
@testable import localvoxtral

/// What herdr's saved-machine files are allowed to mean.
///
/// The local herdr arm reads this to decide whether the local socket's focused
/// pane still describes the surface in front of the user (issue #286). A wrong
/// `notFederated` puts the arm back on the bug, so every shape that is not
/// plainly "no machines saved" resolves to an abstaining value.
final class HerdrMachineFederationTests: XCTestCase {
    private let directory = URL(fileURLWithPath: "/state/herdr/client", isDirectory: true)

    private func reader(
        catalog: HerdrStateFile,
        selection: HerdrStateFile = .absent,
        directories: [URL]? = nil
    ) -> HerdrMachineFederationReader {
        let catalogPath = directory.appendingPathComponent("endpoints.json").path
        let selectionPath = directory.appendingPathComponent("endpoint-selection.json").path
        return HerdrMachineFederationReader(clientDirectories: directories ?? [directory]) { url in
            switch url.path {
            case catalogPath: return catalog
            case selectionPath: return selection
            default: return .absent
            }
        }
    }

    private func json(_ text: String) -> HerdrStateFile {
        .contents(Data(text.utf8))
    }

    private func catalog(selected: String? = nil, profiles: [(String, Bool)]) -> HerdrStateFile {
        let entries = profiles.map { id, enabled in
            """
            {"id":"\(id)","label":"box","target":"box","session":"default","enabled":\(enabled)}
            """
        }
        let selectedField = selected.map { "\"selected_profile\":\"\($0)\"," } ?? ""
        return json("{\"version\":1,\(selectedField)\"ssh\":[\(entries.joined(separator: ","))]}")
    }

    private let profileA = String(repeating: "a", count: 32)
    private let profileB = String(repeating: "b", count: 32)

    /// The profile `catalog(profiles:)` writes for `id`.
    private func machine(_ id: String, enabled: Bool = true) -> HerdrMachineProfile {
        HerdrMachineProfile(id: id, label: "box", target: "box", session: "default", enabled: enabled)
    }

    // Every herdr before 0.9, and every 0.9 user who never ran `machine add`.
    func testNoCatalogIsNotFederated() {
        XCTAssertEqual(reader(catalog: .absent).federation(), .notFederated)
    }

    // A selection file without a catalog names nothing, so it changes nothing.
    func testSelectionWithoutACatalogIsNotFederated() {
        let federation = reader(
            catalog: .absent,
            selection: json("{\"version\":1,\"selected_profile\":\"\(profileA)\"}")
        ).federation()
        XCTAssertEqual(federation, .notFederated)
    }

    // Disabled machines are not connected and cannot be selected, so they leave
    // the arm exactly where it was.
    func testOnlyDisabledMachinesIsNotFederated() {
        let federation = reader(catalog: catalog(profiles: [(profileA, false)])).federation()
        XCTAssertEqual(federation, .notFederated)
    }

    func testSavedMachineWithNoSelectionShowsLocal() {
        let federation = reader(catalog: catalog(profiles: [(profileA, true)])).federation()
        XCTAssertEqual(federation, .showingLocal)
    }

    func testSelectionFileNamingAnEnabledMachineShowsThatMachine() {
        let federation = reader(
            catalog: catalog(profiles: [(profileA, true)]),
            selection: json("{\"version\":1,\"selected_profile\":\"\(profileA)\"}")
        ).federation()
        XCTAssertEqual(federation, .showingMachine(machine(profileA)))
    }

    // herdr writes `null` for Local rather than deleting the file.
    func testSelectionFileWithANullSelectionShowsLocal() {
        let federation = reader(
            catalog: catalog(profiles: [(profileA, true)]),
            selection: json("{\"version\":1,\"selected_profile\":null}")
        ).federation()
        XCTAssertEqual(federation, .showingLocal)
    }

    // herdr's own resolution order: a selection naming a machine that is not
    // enabled falls back to the catalog's copy rather than to Local.
    func testUnusableSelectionFallsBackToTheCatalogSelection() {
        let federation = reader(
            catalog: catalog(selected: profileA, profiles: [(profileA, true)]),
            selection: json("{\"version\":1,\"selected_profile\":\"\(profileB)\"}")
        ).federation()
        XCTAssertEqual(federation, .showingMachine(machine(profileA)))
    }

    func testCatalogSelectionOfADisabledMachineShowsLocal() {
        let federation = reader(
            catalog: catalog(selected: profileB, profiles: [(profileA, true), (profileB, false)])
        ).federation()
        XCTAssertEqual(federation, .showingLocal)
    }

    // herdr writes null for Local and that BEATS the copy the catalog carries,
    // which is how a client that switched back to Local records it.
    func testNullSelectionOverridesTheCatalogSelection() {
        let federation = reader(
            catalog: catalog(selected: profileA, profiles: [(profileA, true)]),
            selection: json("{\"version\":1,\"selected_profile\":null}")
        ).federation()
        XCTAssertEqual(federation, .showingLocal)
    }

    // The startup-restore shape: the catalog carries the selection and no
    // selection file has been written yet.
    func testCatalogSelectionWithNoSelectionFileShowsThatMachine() {
        let federation = reader(
            catalog: catalog(selected: profileA, profiles: [(profileA, true)])
        ).federation()
        XCTAssertEqual(federation, .showingMachine(machine(profileA)))
    }

    // herdr refuses a version it does not know and runs Local-only. This reader
    // abstains rather than decode a future schema as "no machines saved", which
    // would retire the guard on a herdr upgrade alone.
    func testUnknownCatalogVersionAbstains() {
        let file = json("{\"version\":2,\"ssh\":[]}")
        XCTAssertEqual(reader(catalog: file).federation(), .unreadable)
    }

    func testUnknownSelectionVersionAbstains() {
        let federation = reader(
            catalog: catalog(profiles: [(profileA, true)]),
            selection: json("{\"version\":2,\"selected_profile\":null}")
        ).federation()
        XCTAssertEqual(federation, .unreadable)
    }

    func testUnreadableCatalogAbstains() {
        XCTAssertEqual(reader(catalog: .unreadable).federation(), .unreadable)
    }

    func testUndecodableCatalogAbstains() {
        XCTAssertEqual(reader(catalog: json("{\"version\":")).federation(), .unreadable)
    }

    // With machines saved, the selection file is the only thing that separates
    // Local from a machine. Not reading it is not knowing.
    func testUnreadableSelectionAbstains() {
        let federation = reader(
            catalog: catalog(profiles: [(profileA, true)]),
            selection: .unreadable
        ).federation()
        XCTAssertEqual(federation, .unreadable)
    }

    func testUndecodableSelectionAbstains() {
        let federation = reader(
            catalog: catalog(profiles: [(profileA, true)]),
            selection: json("nonsense")
        ).federation()
        XCTAssertEqual(federation, .unreadable)
    }

    // A release build and a development build keep separate state directories.
    // The absent one must not vote the live one down.
    func testTheMoreAbstainingDirectoryWins() {
        let other = URL(fileURLWithPath: "/state/herdr-dev/client", isDirectory: true)
        let federation = reader(
            catalog: catalog(profiles: [(profileA, true)]),
            selection: json("{\"version\":1,\"selected_profile\":\"\(profileA)\"}"),
            directories: [other, directory]
        ).federation()
        XCTAssertEqual(federation, .showingMachine(machine(profileA)))
    }

    // MARK: - The catalog itself (Settings import, federated join arm)

    func testNoCatalogReadsAbsent() {
        XCTAssertEqual(reader(catalog: .absent).catalog(), .absent)
    }

    // Disabled machines stay in the list — the Settings import shows them as
    // saved-but-disconnected — and the selection resolves the same way herdr
    // does: the selection file wins, then the catalog's copy, then Local.
    func testCatalogListsEveryProfileInFileOrderWithTheResolvedSelection() {
        let reading = reader(
            catalog: catalog(selected: profileA, profiles: [(profileB, false), (profileA, true)]),
            selection: json("{\"version\":1,\"selected_profile\":null}")
        ).catalog()
        XCTAssertEqual(
            reading,
            .catalog(HerdrMachineCatalog(
                profiles: [machine(profileB, enabled: false), machine(profileA)],
                selectedProfileID: nil
            ))
        )
    }

    func testCatalogCarriesTheMachineFieldsHerdrListPrints() {
        let file = json("""
            {"version":1,"ssh":[{"id":"\(profileA)","label":"Build machine",
             "target":"ssh://tom@build.example:2222","session":"agents","enabled":true}]}
            """)
        let reading = reader(catalog: file, selection: json("{\"version\":1,\"selected_profile\":\"\(profileA)\"}")).catalog()
        let expected = HerdrMachineProfile(
            id: profileA,
            label: "Build machine",
            target: "ssh://tom@build.example:2222",
            session: "agents",
            enabled: true
        )
        XCTAssertEqual(reading, .catalog(HerdrMachineCatalog(profiles: [expected], selectedProfileID: profileA)))
        if case .catalog(let catalog) = reading {
            XCTAssertEqual(catalog.selectedProfile, expected)
        }
        XCTAssertEqual(
            HerdrMachineFederationReader.federation(from: reading),
            .showingMachine(expected)
        )
    }

    // herdr's own loader is deny_unknown_fields with every field required, so
    // a profile missing one is not a catalog herdr would load either.
    func testProfileMissingARequiredFieldIsUnreadable() {
        let file = json("{\"version\":1,\"ssh\":[{\"id\":\"\(profileA)\",\"enabled\":true}]}")
        XCTAssertEqual(reader(catalog: file).catalog(), .unreadable)
        XCTAssertEqual(reader(catalog: file).federation(), .unreadable)
    }

    // A selection file is only consulted once something is enabled; with
    // nothing enabled there is nothing it could name.
    func testSelectionIsNotReadWhenNothingIsEnabled() {
        let reading = reader(
            catalog: catalog(profiles: [(profileA, false)]),
            selection: .unreadable
        ).catalog()
        XCTAssertEqual(
            reading,
            .catalog(HerdrMachineCatalog(profiles: [machine(profileA, enabled: false)], selectedProfileID: nil))
        )
    }

    func testUnreadableSelectionMakesTheCatalogUnreadable() {
        let reading = reader(
            catalog: catalog(profiles: [(profileA, true)]),
            selection: .unreadable
        ).catalog()
        XCTAssertEqual(reading, .unreadable)
    }

    // Release and development directories: the absent one contributes
    // nothing, an unreadable one poisons the whole reading.
    func testCatalogMergesTheReleaseAndDevelopmentDirectories() {
        let other = URL(fileURLWithPath: "/state/herdr-dev/client", isDirectory: true)
        let reading = reader(
            catalog: catalog(profiles: [(profileA, true)]),
            directories: [other, directory]
        ).catalog()
        XCTAssertEqual(
            reading,
            .catalog(HerdrMachineCatalog(profiles: [machine(profileA)], selectedProfileID: nil))
        )

        let unreadableEverywhere = HerdrMachineFederationReader(clientDirectories: [other, directory]) { url in
            url.path.hasPrefix(other.path) ? .unreadable : .absent
        }
        XCTAssertEqual(unreadableEverywhere.catalog(), .unreadable)
    }

    // MARK: - The live file read

    func testLiveReadDistinguishesAbsentFromUnreadable() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("herdr-federation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let missing = root.appendingPathComponent("endpoints.json")
        XCTAssertEqual(HerdrMachineFederationReader.liveReadFile(missing), .absent)

        // A path under a file rather than a directory is ENOTDIR, still absent.
        let file = root.appendingPathComponent("plain.json")
        try Data("{}".utf8).write(to: file)
        XCTAssertEqual(HerdrMachineFederationReader.liveReadFile(file), .contents(Data("{}".utf8)))
        XCTAssertEqual(
            HerdrMachineFederationReader.liveReadFile(file.appendingPathComponent("deeper.json")),
            .absent
        )

        // Anything that exists but is not a plain file is unreadable, never
        // absent: the arm must not read a surprise as "no machines saved".
        let asDirectory = root.appendingPathComponent("endpoint-selection.json", isDirectory: true)
        try FileManager.default.createDirectory(at: asDirectory, withIntermediateDirectories: true)
        XCTAssertEqual(HerdrMachineFederationReader.liveReadFile(asDirectory), .unreadable)

        // A symlink is not the plain file this reader agreed to read, and the
        // check is `lstat`, so it never follows one.
        let link = root.appendingPathComponent("linked.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        XCTAssertEqual(HerdrMachineFederationReader.liveReadFile(link), .unreadable)
    }

    // MARK: - Session socket classification

    func testSessionSocketClassificationTable() {
        let defaultSession = HerdrMachineProfile.defaultSessionName
        let cases: [(path: String, session: String, expected: Bool, note: String)] = [
            // The default session: `<config dir>/herdr.sock`.
            ("/home/dev/.config/herdr/herdr.sock", defaultSession, true, "release default"),
            // A development build keeps the same layout under herdr-dev.
            ("/home/dev/.config/herdr-dev/herdr.sock", defaultSession, true, "dev default"),
            ("/home/dev/.local/state/herdr/herdr.sock", defaultSession, true, "state-dir shape"),
            // A `sessions/` component is herdr's namespace for NAMED sessions,
            // so these are never the default session's socket.
            ("/home/dev/.config/herdr/sessions/herdr.sock", defaultSession, false, "sessions dir"),
            ("/home/dev/.config/herdr/sessions/agents/herdr.sock", defaultSession, false, "named session"),
            ("/home/dev/.config/herdr-dev/sessions/agents/herdr.sock", defaultSession, false, "dev named"),
            // A session literally named "default" IS the default session, so
            // the sessions-namespaced spelling is refused for it.
            ("/home/dev/.config/herdr/sessions/default/herdr.sock", defaultSession, false, "sessions/default"),
            // Only the LAST components decide: a `sessions` directory higher
            // up (an XDG-relocated root, a directory literally named
            // `sessions`) does not retire the default match.
            ("/tmp/sessions/relocated/herdr/herdr.sock", defaultSession, true, "sessions above the config dir"),
            // ...but exactly `sessions/<name>` stays ambiguous and refuses:
            // it has the named-session shape and no name to check it against.
            ("/tmp/sessions/herdr/herdr.sock", defaultSession, false, "bare sessions/<name>"),
            // Normalization before classification: dot-dot, repeated
            // separators, and a trailing `/.` are the same path herdr wrote.
            ("/home/dev/.config/herdr/sessions/agents/../agents/herdr.sock", "agents", true, "dot-dot normalizes"),
            ("//sessions//agents//herdr.sock", "agents", true, "repeated separators collapse"),
            ("/home/dev/.config/herdr/sessions/agents/herdr.sock/.", "agents", true, "trailing /. normalizes away"),
            ("/home/dev/.config/herdr/./herdr.sock", defaultSession, true, "dot normalizes"),
            // Case is significant: herdr writes the paths, and the classifier
            // may not assume the filesystem's case rules.
            ("/home/dev/.config/herdr/Sessions/agents/herdr.sock", "agents", false, "Sessions is not sessions"),
            ("/home/dev/.config/herdr/Sessions/agents/herdr.sock", defaultSession, true, "Sessions is not sessions/<name> either"),
            // A named session: `<config dir>/sessions/<name>/herdr.sock`.
            ("/home/dev/.config/herdr/sessions/agents/herdr.sock", "agents", true, "named"),
            ("/home/dev/.config/herdr-dev/sessions/agents/herdr.sock", "agents", true, "dev named"),
            // Wrong name, wrong component, or no sessions component at all.
            ("/home/dev/.config/herdr/sessions/build/herdr.sock", "agents", false, "other name"),
            ("/home/dev/.config/herdr/sessions/sessions/agents/herdr.sock", "agents", true, "doubled component still ends correctly"),
            ("/home/dev/.config/herdr/agents/herdr.sock", "agents", false, "no sessions component"),
            // The session name is herdr's `validate_name`: empty, `.`, `..`,
            // overlong, and non-charset names classify nothing.
            ("/home/dev/.config/herdr/sessions/agents/herdr.sock", "", false, "empty session name"),
            ("/home/dev/.config/herdr/sessions/agents/herdr.sock", ".", false, "dot session name"),
            ("/home/dev/.config/herdr/sessions/agents/herdr.sock", "..", false, "dot-dot session name"),
            ("/home/dev/.config/herdr/sessions/agents/herdr.sock", "a gents", false, "session name charset"),
            ("/home/dev/.config/herdr/sessions/agents/herdr.sock", String(repeating: "a", count: 65), false, "session name length"),
            // Not a socket path herdr would derive from any session.
            ("/home/dev/.config/herdr/herdr-client.sock", defaultSession, false, "client socket"),
            ("/home/dev/.config/herdr", defaultSession, false, "no socket file name"),
            ("herdr.sock", defaultSession, false, "bare file name"),
        ]
        for testCase in cases {
            XCTAssertEqual(
                HerdrSessionSocket.isSocket(testCase.path, ofSessionNamed: testCase.session),
                testCase.expected,
                "\(testCase.note): \(testCase.path) for session \(testCase.session)"
            )
        }
    }
}
