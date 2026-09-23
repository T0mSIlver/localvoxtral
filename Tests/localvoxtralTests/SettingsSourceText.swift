import Foundation

/// The Settings window's Swift source as one string, for the tests that pin
/// copy and layout at the source (no render seam exists for them): the root
/// `SettingsView.swift` followed by every file under `Settings/`, in name
/// order. Read from the repo rather than inlined so the pins run against what
/// actually ships.
enum SettingsSourceText {
    static func load() throws -> String {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // SettingsSourceText.swift
            .deletingLastPathComponent()  // localvoxtralTests
            .deletingLastPathComponent()  // Tests
            .appendingPathComponent("Sources/localvoxtral")
        let paneFiles = try FileManager.default
            .contentsOfDirectory(
                at: sources.appendingPathComponent("Settings"),
                includingPropertiesForKeys: nil
            )
            .filter { $0.pathExtension == "swift" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        return try ([sources.appendingPathComponent("SettingsView.swift")] + paneFiles)
            .map { try String(contentsOf: $0, encoding: .utf8) }
            .joined(separator: "\n")
    }

    /// Where the top-level declaration running at `index` ends: the next
    /// top-level `struct`, or the next file's imports.
    static func endOfTopLevelDeclaration(
        in source: String, after index: String.Index
    ) -> String.Index {
        ["\nstruct ", "\nprivate struct ", "\nimport "]
            .compactMap { source.range(of: $0, range: index..<source.endIndex)?.lowerBound }
            .min() ?? source.endIndex
    }
}
