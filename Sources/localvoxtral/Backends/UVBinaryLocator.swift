import Foundation

protocol UVBinaryLocating: Sendable {
    func uvBinaryURL() -> URL?
}

struct UVBinaryLocator: UVBinaryLocating {
    private let layout: BackendInstallLayout

    init(layout: BackendInstallLayout = BackendInstallLayout()) {
        self.layout = layout
    }

    func uvBinaryURL() -> URL? {
        let fileManager = FileManager.default
        let candidates = [
            layout.managedUVBinary,
            URL(fileURLWithPath: "/opt/homebrew/bin/uv"),
            URL(fileURLWithPath: "/usr/local/bin/uv"),
        ]

        return candidates.first { url in
            fileManager.isExecutableFile(atPath: url.path)
        }
    }
}
