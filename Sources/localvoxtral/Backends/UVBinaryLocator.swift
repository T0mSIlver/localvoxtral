import Foundation

protocol UVBinaryLocating: Sendable {
    func uvBinaryURL() -> URL?
}

struct UVBinaryLocator: UVBinaryLocating {
    func uvBinaryURL() -> URL? {
        let fileManager = FileManager.default
        let candidates = [
            Bundle.main.executableURL?
                .deletingLastPathComponent()
                .appendingPathComponent("uv"),
            URL(fileURLWithPath: "/opt/homebrew/bin/uv"),
            URL(fileURLWithPath: "/usr/local/bin/uv"),
        ].compactMap { $0 }

        return candidates.first { url in
            fileManager.isExecutableFile(atPath: url.path)
        }
    }
}
