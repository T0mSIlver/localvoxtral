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
        XCTAssertEqual(federation, .showingMachine)
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
        XCTAssertEqual(federation, .showingMachine)
    }

    func testCatalogSelectionOfADisabledMachineShowsLocal() {
        let federation = reader(
            catalog: catalog(selected: profileB, profiles: [(profileA, true), (profileB, false)])
        ).federation()
        XCTAssertEqual(federation, .showingLocal)
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
        XCTAssertEqual(federation, .showingMachine)
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
    }
}
