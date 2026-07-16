import Foundation
import SpeechEngine
import SpeechEngineText

/// localvoxtral's bundled realtime ASR engine: loads the Voxtral MLX model and serves the
/// OpenAI-Realtime websocket subset on loopback, a drop-in for the Python `voxmlx` process.
/// Spawned and supervised by the app (BackendProcessSupervisor); the model is loaded BEFORE
/// the listener binds, so `/health` becoming reachable is the readiness signal (matching the
/// supervisor's readinessURL contract).
@main
struct SpeechdMain {
    static func main() async {
        do {
            try await run(SpeechdOptionParser.parse(Array(CommandLine.arguments.dropFirst())))
        } catch {
            FileHandle.standardError.write(Data("speechd: \(error)\n".utf8))
            exit(1)
        }
    }

    static func run(_ options: SpeechdLaunchOptions) async throws {
        if options.benchmark != nil {
            try await StreamingSpeechBenchmark.run(options)
            return
        }

        // Load BEFORE binding the listener so /health only answers once inference is ready.
        let server = try await RealtimeSpeechServer.load(
            modelID: options.modelID,
            modelRevision: options.modelRevision,
            modelDirectory: options.modelDirectory,
            port: options.port,
            transcriptionDelayMs: options.transcriptionDelayMs,
            cacheLimitMB: options.cacheLimitMB,
            stepMilliseconds: options.stepMilliseconds
        )

        // Exit if the supervising app dies, so a killed app never orphans the model.
        var watchdog: ParentProcessWatchdog?
        if let pid = options.parentPID {
            watchdog = ParentProcessWatchdog(parentPID: pid) {
                FileHandle.standardError.write(Data("speechd: parent \(pid) exited; stopping\n".utf8))
                exit(0)
            }
        }
        _ = watchdog  // retained for the process lifetime

        // A listener that dies in a live process is invisible to the supervisor (it only
        // watches process exit) — die loudly to get restarted.
        server.onListenerFailure = { error in
            FileHandle.standardError.write(Data("speechd: listener failed: \(error)\n".utf8))
            exit(1)
        }
        try await server.start()
        FileHandle.standardError.write(
            Data("speechd: ready on 127.0.0.1:\(server.boundPort)\n".utf8))

        // Park forever; the watchdog and listener-failure paths own process exit.
        try await withUnsafeThrowingContinuation { (_: UnsafeContinuation<Void, Error>) in }
    }
}
