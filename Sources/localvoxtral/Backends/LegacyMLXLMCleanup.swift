import Foundation

/// Best-effort removal of the former mlx-lm polishing backend left
/// behind on user Macs after the bundled `localvoxtral-polishd` helper
/// replaced it (2026-07). Idempotent: once everything is gone, running it
/// again is a silent no-op, so it runs on every launch.
///
/// The part-3 transition deliberately left voxmlx and the shared installer
/// support for part 4. `LegacyVoxmlxCleanup` now owns that final sweep.
/// Downloaded model weights remain untouched in the shared HF cache.
struct LegacyMLXLMCleanup {
    private let layout: BackendInstallLayout
    private let fileManager: FileManager

    /// uv tool venv directory name (`tools/mlx-lm`) and `installed.json` key.
    private static let legacyToolID = "mlx-lm"
    /// Entry points uv linked into `bin/`. The wheel installs a BARE `mlx_lm`
    /// console script alongside the dotted ones (`mlx_lm.server`,
    /// `mlx_lm.generate`, …). An earlier `"mlx_lm."` prefix here removed the
    /// dotted siblings and walked straight past the bare one, leaving it behind
    /// as a dangling symlink — and making a later `uv tool install mlx-lm` fail
    /// with "Executable already exists". Found by hand-testing the 0.7.4 → 0.8.0
    /// upgrade; the undotted prefix covers both shapes.
    private static let legacyBinPrefix = "mlx_lm"
    /// Wheels the installer parked in `downloads/`.
    private static let legacyWheelPrefix = "mlx_lm-"

    init(layout: BackendInstallLayout = BackendInstallLayout(), fileManager: FileManager = .default) {
        self.layout = layout
        self.fileManager = fileManager
    }

    /// Removes whatever legacy pieces exist and returns their URLs (empty when
    /// there was nothing to do). Failures are logged and skipped — cleanup
    /// must never block launch.
    @discardableResult
    func run() -> [URL] {
        var removed: [URL] = []

        removeIfPresent(
            layout.tools.appendingPathComponent(Self.legacyToolID, isDirectory: true),
            into: &removed
        )
        for entry in entries(of: layout.toolBin, withPrefix: Self.legacyBinPrefix) {
            removeIfPresent(entry, into: &removed)
        }
        for entry in entries(of: layout.downloads, withPrefix: Self.legacyWheelPrefix) {
            removeIfPresent(entry, into: &removed)
        }
        if dropLegacyInstalledMarkerEntry() {
            removed.append(installedMarkerURL)
        }

        if !removed.isEmpty {
            // notice, not info: info-level messages aren't reliably persisted,
            // so a `log show` after the fact would miss the only trace of a
            // launch-time deletion of user files.
            Log.backends.notice(
                "Removed orphaned mlx-lm install: \(removed.map(\.lastPathComponent).joined(separator: ", "), privacy: .public)"
            )
        }
        return removed
    }

    private var installedMarkerURL: URL {
        layout.root.appendingPathComponent("installed.json")
    }

    /// Directory listing by name prefix. Dangling symlinks (uv links bin
    /// entries into the tool venv, which may already be gone) still show up
    /// here, unlike with `fileExists(atPath:)`.
    private func entries(of directory: URL, withPrefix prefix: String) -> [URL] {
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else {
            return []
        }
        return names
            .filter { $0.hasPrefix(prefix) }
            .map { directory.appendingPathComponent($0) }
    }

    private func removeIfPresent(_ url: URL, into removed: inout [URL]) {
        // removeItem handles dangling symlinks (it unlinks, not resolves);
        // a missing path throws NSFileNoSuchFileError, which is the no-op case.
        do {
            try fileManager.removeItem(at: url)
            removed.append(url)
        } catch let error as NSError
            where error.domain == NSCocoaErrorDomain && error.code == NSFileNoSuchFileError
        {
            // Already gone — the idempotent path.
        } catch {
            Log.backends.error(
                "Orphaned mlx-lm cleanup failed for \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// Drops the `mlx-lm` entry from `installed.json` so the marker only
    /// tracks backends the app still installs. Returns true when it rewrote
    /// the file.
    private func dropLegacyInstalledMarkerEntry() -> Bool {
        guard fileManager.fileExists(atPath: installedMarkerURL.path),
              let data = try? Data(contentsOf: installedMarkerURL),
              var marker = (try? JSONSerialization.jsonObject(with: data)) as? [String: String],
              marker.removeValue(forKey: Self.legacyToolID) != nil
        else {
            return false
        }
        do {
            let rewritten = try JSONSerialization.data(
                withJSONObject: marker,
                options: [.prettyPrinted, .sortedKeys]
            )
            try rewritten.write(to: installedMarkerURL, options: .atomic)
            return true
        } catch {
            Log.backends.error(
                "Orphaned mlx-lm cleanup failed to rewrite installed.json: \(error.localizedDescription, privacy: .public)"
            )
            return false
        }
    }
}

extension LegacyMLXLMCleanup: @unchecked Sendable {}
