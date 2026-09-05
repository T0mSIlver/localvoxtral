import XCTest

@testable import localvoxtral

/// The compile gate on the dogfood control socket, checked against the SOURCE.
///
/// This file is deliberately NOT wrapped in `#if LOCALVOXTRAL_DOGFOOD`: it runs
/// in both configurations, which is the only way a test can fail when someone
/// removes the gate. A test that only exists in a dogfood build cannot notice
/// that the socket leaked into a shipping one.
///
/// It scans sources rather than symbols because that is the property worth
/// pinning. `nm` on a release binary proves one build was clean; a scan proves
/// that no reference to the socket exists outside the flag, which is what makes
/// every future release build clean. (The binary check is real proof too, and
/// belongs in the PR's Proof section — it just cannot run in CI on both
/// configurations from one test target.)
final class DogfoodControlBuildBoundaryTests: XCTestCase {
    /// Identifiers and literals that must never be reachable without the flag.
    ///
    /// Substrings, matched anywhere in a line: a match inside a comment is a
    /// finding too, because a comment naming the socket outside the gate means
    /// the code it describes is one edit away from being there.
    private static let guardedTokens = [
        "DogfoodControlSocket",
        "DogfoodControlService",
        "DogfoodControlProtocol",
        "DogfoodControlJSON",
        "startDogfoodControlSocket",
        "dogfoodControlSocket",
        "dogfoodControlService",
        "dogfoodControlSocketEnabled",
        "dogfood_control_socket_enabled",
        "dogfoodHandleModifierOnlyTap",
        "dogfoodNoteResolvedJoin",
        "control.sock",
    ]

    /// Every file whose entire contents are the control socket. Each must open
    /// with the flag, so the file compiles to nothing without it.
    private static let controlSocketFiles = [
        "Sources/localvoxtral/Dogfood/DogfoodControlProtocol.swift",
        "Sources/localvoxtral/Dogfood/DogfoodControlService.swift",
        "Sources/localvoxtral/Dogfood/DogfoodControlSocket.swift",
    ]

    func testEveryControlSocketFileIsGatedFromItsFirstLine() throws {
        let root = try Self.repositoryRoot()
        for relative in Self.controlSocketFiles {
            let url = root.appendingPathComponent(relative)
            let source = try String(contentsOf: url, encoding: .utf8)
            let firstCode = source
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .first { !$0.isEmpty && !$0.hasPrefix("//") }
            XCTAssertEqual(
                firstCode,
                "#if LOCALVOXTRAL_DOGFOOD",
                "\(relative) must open with the dogfood flag"
            )
        }
    }

    /// Every mention of the control socket, anywhere in `Sources/`, sits inside
    /// an ACTIVE `#if LOCALVOXTRAL_DOGFOOD` branch — never in its `#else`, and
    /// never outside a conditional at all.
    func testNoControlSocketReferenceEscapesTheDogfoodFlag() throws {
        let root = try Self.repositoryRoot()
        let sources = root.appendingPathComponent("Sources")
        var escapes: [String] = []

        let enumerator = FileManager.default.enumerator(
            at: sources,
            includingPropertiesForKeys: nil
        )
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            let source = try String(contentsOf: url, encoding: .utf8)
            let relative = url.path.replacingOccurrences(of: root.path + "/", with: "")
            for (number, line) in Self.ungatedLines(in: source) {
                for token in Self.guardedTokens where line.contains(token) {
                    escapes.append("\(relative):\(number) mentions \(token) outside the flag")
                }
            }
        }

        XCTAssertEqual(
            escapes, [],
            """
            The dogfood control socket must not be reachable without \
            LOCALVOXTRAL_DOGFOOD. Wrap the offending lines, or move them into a \
            file that opens with the flag.
            """
        )
    }

    /// A scanner that would pass anything is worse than none, so the scanner
    /// itself is pinned: gated lines are invisible, un-gated ones are not, and
    /// the `#else` of a dogfood conditional counts as un-gated.
    func testTheScannerSeesTheCasesItExistsToCatch() {
        let source = """
        let a = DogfoodControlSocket.self
        #if LOCALVOXTRAL_DOGFOOD
        let b = DogfoodControlSocket.self
        #else
        let c = DogfoodControlSocket.self
        #endif
        #if DEBUG
        let d = DogfoodControlSocket.self
        #if LOCALVOXTRAL_DOGFOOD
        let e = DogfoodControlSocket.self
        #endif
        #endif
        let f = DogfoodControlSocket.self
        """
        let ungated = Self.ungatedLines(in: source)
            .filter { $0.line.contains("DogfoodControlSocket") }
            .map(\.number)
        XCTAssertEqual(ungated, [1, 5, 8, 13])
    }

    /// In a dogfood build the socket must actually be there — otherwise the
    /// test above could pass by the feature having quietly disappeared.
    func testTheSocketExistsExactlyInADogfoodBuild() {
        #if LOCALVOXTRAL_DOGFOOD
        XCTAssertTrue(DogfoodControlSocket.defaultSocketPath().hasSuffix("control.sock"))
        #else
        // Nothing to assert: naming the type here would itself be a violation
        // of the boundary the test above enforces.
        XCTAssertTrue(true)
        #endif
    }

    // MARK: - Scanner

    /// Lines NOT inside an active `#if LOCALVOXTRAL_DOGFOOD` branch, 1-based.
    ///
    /// Conservative in the direction that matters: an `#elseif` clears the
    /// dogfood-ness of its frame (we do not evaluate conditions), and an
    /// `#else` un-gates it, so anything ambiguous is reported rather than
    /// waved through.
    static func ungatedLines(in source: String) -> [(number: Int, line: String)] {
        struct Frame {
            var isDogfood: Bool
            var inElse = false
        }
        var stack: [Frame] = []
        var result: [(Int, String)] = []
        for (index, raw) in source.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = String(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#if") {
                stack.append(Frame(isDogfood: trimmed.contains("LOCALVOXTRAL_DOGFOOD")))
                continue
            }
            if trimmed.hasPrefix("#elseif") {
                if !stack.isEmpty { stack[stack.count - 1].isDogfood = false }
                continue
            }
            if trimmed.hasPrefix("#else") {
                if !stack.isEmpty { stack[stack.count - 1].inElse = true }
                continue
            }
            if trimmed.hasPrefix("#endif") {
                if !stack.isEmpty { stack.removeLast() }
                continue
            }
            let gated = stack.contains { $0.isDogfood && !$0.inElse }
            if !gated { result.append((index + 1, line)) }
        }
        return result
    }

    /// Tests/localvoxtralTests/<this file> -> repository root.
    ///
    /// A missing root FAILS rather than skipping: a boundary check that can
    /// quietly not run is exactly as good as no boundary check, and SwiftPM
    /// always compiles this target from the tree it is in.
    static func repositoryRoot() throws -> URL {
        let here = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: here.appendingPathComponent("Package.swift").path
            ),
            "expected the repository root at \(here.path)"
        )
        return here
    }
}
