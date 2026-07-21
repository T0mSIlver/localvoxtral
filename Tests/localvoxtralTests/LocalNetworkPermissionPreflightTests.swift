import Foundation
import XCTest
@testable import localvoxtral

@MainActor
final class LocalNetworkPermissionPreflightTests: XCTestCase {
    func testPolicySelectsPrivateAndLocalOnlyEndpoints() throws {
        let cases: [(String, String, UInt16)] = [
            ("ws://10.0.0.8/realtime", "10.0.0.8", 80),
            ("wss://172.31.255.2/realtime", "172.31.255.2", 443),
            ("http://192.168.50.4:8080/v1/chat/completions", "192.168.50.4", 8080),
            ("http://169.254.4.2:8472/v1/chat/completions", "169.254.4.2", 8472),
            ("http://100.64.1.2:9000/v1/chat/completions", "100.64.1.2", 9000),
            ("http://[fd00::5]:8080/v1/chat/completions", "fd00::5", 8080),
            ("ws://[fe80::1234]:8000/realtime", "fe80::1234", 8000),
            ("ws://dictation-box.local:8000/realtime", "dictation-box.local", 8000),
            ("http://polisher.home.arpa:8080/v1/chat/completions", "polisher.home.arpa", 8080),
            ("ws://speech-server:8000/realtime", "speech-server", 8000),
        ]

        for (rawURL, expectedHost, expectedPort) in cases {
            let endpoint = try XCTUnwrap(URL(string: rawURL))
            let target = try XCTUnwrap(
                LocalNetworkEndpointPolicy.preflightTarget(for: endpoint),
                "expected a preflight target for \(rawURL)"
            )
            XCTAssertEqual(target.host, expectedHost, rawURL)
            XCTAssertEqual(target.port, expectedPort, rawURL)
        }
    }

    func testPolicyRejectsLoopbackPublicAndUnsupportedEndpoints() throws {
        let endpoints = [
            "ws://127.0.0.1:8000/realtime",
            "ws://127.22.4.9:8000/realtime",
            "http://localhost:8080/v1/chat/completions",
            "http://[::1]:8080/v1/chat/completions",
            "wss://api.openai.com/v1/realtime",
            "https://8.8.8.8/v1/chat/completions",
            "https://[2606:4700:4700::1111]/v1/chat/completions",
            "file:///tmp/realtime.sock",
        ]

        for rawURL in endpoints {
            let endpoint = try XCTUnwrap(URL(string: rawURL))
            XCTAssertNil(
                LocalNetworkEndpointPolicy.preflightTarget(for: endpoint),
                "must not probe \(rawURL)"
            )
        }
    }

    func testEndpointEditsProbeOnlyEligibleActiveExternalBackends() {
        let (settings, suiteName) = makeSettings()
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        settings.dictationBackendMode = .externalURL
        settings.polishingBackendMode = .externalURL
        settings.llmPolishingEnabled = false
        let preflight = RecordingLocalNetworkPermissionPreflight()
        let viewModel = DictationViewModel(
            settings: settings,
            localNetworkPermissionPreflight: preflight,
            startRuntimeServices: false
        )

        viewModel.applyRealtimeEndpointChange("ws://192.168.1.20:8000/v1/realtime")
        viewModel.applyLLMPolishingEndpointChange("http://10.0.0.9:8080/v1/chat/completions")
        viewModel.applyRealtimeEndpointChange("ws://127.0.0.1:8000/v1/realtime")
        viewModel.applyLLMPolishingEndpointChange("https://api.example.com/v1/chat/completions")

        XCTAssertEqual(
            preflight.requests.map(\.endpoint.absoluteString),
            [
                "ws://192.168.1.20:8000/v1/realtime",
                "http://10.0.0.9:8080/v1/chat/completions",
            ]
        )
        XCTAssertEqual(
            preflight.requests.map(\.reason),
            ["dictation endpoint updated", "polishing endpoint updated"]
        )
    }

    func testEndpointEditWhileManagedWaitsUntilExternalModeSwitch() {
        let (settings, suiteName) = makeSettings()
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        settings.dictationBackendMode = .managedLocal
        settings.polishingBackendMode = .managedLocal
        settings.llmPolishingEnabled = false
        let preflight = RecordingLocalNetworkPermissionPreflight()
        let viewModel = DictationViewModel(
            settings: settings,
            localNetworkPermissionPreflight: preflight,
            startRuntimeServices: false
        )

        viewModel.applyRealtimeEndpointChange("ws://192.168.2.30:8000/v1/realtime")
        viewModel.applyLLMPolishingEndpointChange("http://10.2.0.4:8080/v1/chat/completions")
        XCTAssertTrue(preflight.requests.isEmpty)

        viewModel.applyDictationBackendModeChange(.externalURL)
        viewModel.applyPolishingBackendModeChange(.externalURL)

        XCTAssertEqual(
            preflight.requests.map(\.endpoint.absoluteString),
            [
                "ws://192.168.2.30:8000/v1/realtime",
                "http://10.2.0.4:8080/v1/chat/completions",
            ]
        )
    }

    func testConfiguredExternalEndpointsArePreflightedBeforeUse() {
        let (settings, suiteName) = makeSettings()
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        settings.dictationBackendMode = .externalURL
        settings.polishingBackendMode = .externalURL
        settings.realtimeAPIEndpointURL = "ws://192.168.3.5:8000/v1/realtime"
        settings.llmPolishingEndpointURL = "http://polisher.local:8080/v1/chat/completions"
        settings.llmPolishingEnabled = false
        let preflight = RecordingLocalNetworkPermissionPreflight()
        let viewModel = DictationViewModel(
            settings: settings,
            localNetworkPermissionPreflight: preflight,
            startRuntimeServices: false
        )

        viewModel.preflightConfiguredLocalNetworkEndpoints()

        XCTAssertEqual(
            preflight.requests.map(\.endpoint.absoluteString),
            [
                "ws://192.168.3.5:8000/v1/realtime",
                "http://polisher.local:8080/v1/chat/completions",
            ]
        )
    }

    func testPackagedInfoPlistDeclaresLocalNetworkUsageWithoutBonjourBrowsing() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let packageScript = repoRoot.appendingPathComponent("scripts/package_app.sh")
        let source = try String(contentsOf: packageScript, encoding: .utf8)

        XCTAssertTrue(source.contains("<key>NSLocalNetworkUsageDescription</key>"))
        XCTAssertTrue(source.contains("transcription and polishing servers you configure"))
        XCTAssertFalse(source.contains("<key>NSBonjourServices</key>"))

        for key in [
            "NSDesktopFolderUsageDescription",
            "NSDocumentsFolderUsageDescription",
            "NSDownloadsFolderUsageDescription",
            "NSNetworkVolumesUsageDescription",
            "NSRemovableVolumesUsageDescription",
        ] {
            XCTAssertTrue(source.contains("<key>\(key)</key>"), "missing \(key)")
        }
    }

    private func makeSettings() -> (SettingsStore, String) {
        let suiteName = "localvoxtral.LocalNetworkPreflight.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (SettingsStore(defaults: defaults, environment: [:]), suiteName)
    }
}

@MainActor
private final class RecordingLocalNetworkPermissionPreflight:
    LocalNetworkPermissionPreflighting
{
    struct Request {
        let endpoint: URL
        let reason: String
    }

    private(set) var requests: [Request] = []

    func preflight(endpoint: URL, reason: String) {
        requests.append(Request(endpoint: endpoint, reason: reason))
    }
}
