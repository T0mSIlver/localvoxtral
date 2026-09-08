import Foundation

#if canImport(Darwin)
import Darwin

/// What herdr's saved-machine feature says about the client on this Mac.
///
/// herdr 0.9.0 attaches several SSH machines to ONE local client
/// (`herdr machine add`). While a remote machine is selected, the local server
/// keeps a focused pane it has merely stopped presenting, so `pane.current` on
/// the local socket stops describing what the user is looking at. The local
/// herdr arm asks this before it trusts that answer (issue #286).
///
/// Federation lives entirely in herdr's CLIENT: the catalog is a per-user file,
/// no server knows about it, and the socket API exposes nothing about it. Files
/// are therefore the only place to read it, short of running herdr's own CLI,
/// which a GUI app cannot locate reliably.
enum HerdrMachineFederation: Sendable, Equatable {
    /// No saved machines. The local socket's focused pane is what the surface
    /// displays, exactly as it was before 0.9.
    case notFederated
    /// Machines are saved and the client is showing Local.
    case showingLocal
    /// Machines are saved and the client is showing one of them.
    case showingMachine
    /// herdr's state is present but could not be read or decoded.
    case unreadable

    /// The more abstaining of two readings, used to merge the release and
    /// development state directories. A user runs one of them; the other is
    /// absent, which reads as `notFederated` and never masks the live one.
    static func moreAbstaining(
        _ first: HerdrMachineFederation, _ second: HerdrMachineFederation
    ) -> HerdrMachineFederation {
        func rank(_ value: HerdrMachineFederation) -> Int {
            switch value {
            case .notFederated: return 0
            case .showingLocal: return 1
            case .showingMachine: return 2
            case .unreadable: return 3
            }
        }
        return rank(first) >= rank(second) ? first : second
    }
}

/// One state file as the reader found it. `absent` and `unreadable` are kept
/// apart on purpose: a missing catalog means this user saved no machines, while
/// a catalog that exists and cannot be read means the arm knows nothing and
/// must abstain.
enum HerdrStateFile: Sendable, Equatable {
    case absent
    case contents(Data)
    case unreadable
}

/// Reads herdr's client-side machine catalog and machine selection.
///
/// The two files are `<state dir>/client/endpoints.json` (the saved machines)
/// and `<state dir>/client/endpoint-selection.json` (the one being viewed,
/// rewritten by the client on every switch). herdr's state directory is
/// `$XDG_STATE_HOME/herdr` when that variable is set and `~/.local/state/herdr`
/// otherwise, with `herdr-dev` in place of `herdr` for a development build.
///
/// KNOWN RESIDUAL: a GUI app does not see the user's shell environment, so a
/// user who exports `XDG_STATE_HOME` relocates the catalog somewhere this
/// reader cannot find, and reads back `notFederated`. That leaves them on the
/// pre-0.9 behavior this guard exists to correct. Closing it needs herdr's own
/// CLI, whose path a GUI app cannot resolve either.
struct HerdrMachineFederationReader: Sendable {
    private let clientDirectories: [URL]
    private let readFile: @Sendable (URL) -> HerdrStateFile

    init(clientDirectories: [URL], readFile: @escaping @Sendable (URL) -> HerdrStateFile) {
        self.clientDirectories = clientDirectories
        self.readFile = readFile
    }

    /// Production reader over this user's home directory.
    static func live() -> HerdrMachineFederationReader {
        HerdrMachineFederationReader(
            clientDirectories: Self.liveClientDirectories(),
            readFile: Self.liveReadFile
        )
    }

    func federation() -> HerdrMachineFederation {
        clientDirectories
            .map(federation(inClientDirectory:))
            .reduce(.notFederated, HerdrMachineFederation.moreAbstaining)
    }

    private func federation(inClientDirectory directory: URL) -> HerdrMachineFederation {
        let catalogFile = readFile(directory.appendingPathComponent("endpoints.json"))
        switch catalogFile {
        case .absent:
            // No catalog is the state of every herdr before 0.9 and of every
            // 0.9 user who saved no machine. Nothing to guard against.
            return .notFederated
        case .unreadable:
            return .unreadable
        case .contents(let data):
            guard let catalog = try? JSONDecoder().decode(Catalog.self, from: data),
                  catalog.version == Self.supportedStateVersion
            else { return .unreadable }
            let enabled = Set(catalog.ssh?.filter(\.enabled).map(\.id) ?? [])
            guard !enabled.isEmpty else { return .notFederated }
            switch selectedProfile(
                inClientDirectory: directory, enabledProfiles: enabled, catalog: catalog
            ) {
            case .success(let selected):
                return selected == nil ? .showingLocal : .showingMachine
            case .failure:
                return .unreadable
            }
        }
    }

    /// Which machine the client is showing, or nil for Local.
    ///
    /// herdr resolves this in `load_from_paths` (`src/client/endpoint/catalog.rs`)
    /// and this follows it exactly. A selection file naming an enabled profile
    /// wins. A selection file saying Local wins too, and overrides the copy the
    /// catalog carries. Only a selection that names a profile which is gone or
    /// disabled loses, and then the catalog's copy answers. A selection file
    /// that exists and cannot be decoded fails instead, because with machines
    /// saved it is the only thing that separates Local from a machine.
    private func selectedProfile(
        inClientDirectory directory: URL,
        enabledProfiles: Set<String>,
        catalog: Catalog
    ) -> Result<String?, SelectionUnreadable> {
        let catalogSelection = catalog.selectedProfile.flatMap { enabledProfiles.contains($0) ? $0 : nil }
        switch readFile(directory.appendingPathComponent("endpoint-selection.json")) {
        case .absent:
            return .success(catalogSelection)
        case .unreadable:
            return .failure(SelectionUnreadable())
        case .contents(let data):
            guard let selection = try? JSONDecoder().decode(Selection.self, from: data),
                  selection.version == Self.supportedStateVersion
            else { return .failure(SelectionUnreadable()) }
            guard let selected = selection.selectedProfile else {
                // herdr writes null for Local, and serde reads a missing field
                // as the same None, so both mean Local here.
                return .success(nil)
            }
            return .success(enabledProfiles.contains(selected) ? selected : catalogSelection)
        }
    }

    private struct SelectionUnreadable: Error {}

    /// herdr refuses any other version in its own loader and runs the client
    /// Local-only when it does. This reader abstains instead of guessing: a
    /// future schema that renames or reinterprets these fields would otherwise
    /// decode as "no machines saved" and silently retire the guard.
    private static let supportedStateVersion = 1

    private struct Catalog: Decodable {
        struct Profile: Decodable {
            var id: String
            var enabled: Bool
        }

        var version: Int
        var selectedProfile: String?
        var ssh: [Profile]?

        enum CodingKeys: String, CodingKey {
            case version
            case selectedProfile = "selected_profile"
            case ssh
        }
    }

    private struct Selection: Decodable {
        var version: Int
        var selectedProfile: String?

        enum CodingKeys: String, CodingKey {
            case version
            case selectedProfile = "selected_profile"
        }
    }

    // MARK: - Live file access

    private static func liveClientDirectories() -> [URL] {
        let state: URL
        if let overridden = ProcessInfo.processInfo.environment["XDG_STATE_HOME"], !overridden.isEmpty {
            state = URL(fileURLWithPath: overridden, isDirectory: true)
        } else {
            state = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent(".local/state", isDirectory: true)
        }
        // A development build of herdr keeps its own directory, and a user
        // running one is federated just the same.
        return ["herdr", "herdr-dev"].map {
            state.appendingPathComponent($0, isDirectory: true)
                .appendingPathComponent("client", isDirectory: true)
        }
    }

    /// Reads one state file, refusing anything that is not a plain file this
    /// user owns. The refusals are `unreadable`, never `absent`: a path that
    /// exists in a shape this reader does not understand is exactly the case
    /// the arm must not treat as "no machines saved".
    static let liveReadFile: @Sendable (URL) -> HerdrStateFile = { url in
        // herdr caps its own catalog at 64 KiB, so a larger file is not a
        // catalog this reader understands.
        let maximumBytes: off_t = 64 * 1024
        var status = stat()
        guard lstat(url.path, &status) == 0 else {
            return errno == ENOENT || errno == ENOTDIR ? .absent : .unreadable
        }
        guard status.st_mode & S_IFMT == S_IFREG,
              status.st_uid == geteuid(),
              status.st_size <= maximumBytes,
              let data = try? Data(contentsOf: url, options: [.uncached])
        else { return .unreadable }
        return .contents(data)
    }
}
#endif
