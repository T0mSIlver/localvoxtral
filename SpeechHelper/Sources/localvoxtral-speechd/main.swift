import Foundation
import SpeechEngine

// Placeholder entry point. The bundled realtime ASR server (a loopback OpenAI-Realtime
// websocket speaking the subset the app already uses with voxmlx, plus a parent-pid
// watchdog) lands in the follow-up that wires this helper into BackendManager. For now the
// deliverable is the vendored+fixed engine (SpeechEngine) and its Metal-free delta tests.
FileHandle.standardError.write(
    Data("localvoxtral-speechd: engine vendored; realtime server not yet wired.\n".utf8))
exit(0)
