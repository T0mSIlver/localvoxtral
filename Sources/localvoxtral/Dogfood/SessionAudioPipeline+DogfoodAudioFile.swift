#if LOCALVOXTRAL_DOGFOOD

import Foundation

extension SessionAudioPipeline {
    /// Loads the file on every session start, so a file that is missing or in
    /// the wrong format fails THAT dictation with its reason in `lastError`.
    /// Falling back to the microphone instead would let an end-to-end run pass
    /// or fail on whatever the room sounded like.
    func startDogfoodAudioFileSource(
        _ url: URL,
        chunkHandler: @escaping MicrophoneCaptureService.ChunkHandler
    ) throws {
        dogfoodAudioFileSource?.stop()
        let source = try DogfoodAudioFileSource(contentsOf: url, sleep: dogfoodAudioFileSleep)
        dogfoodAudioFileSource = source
        source.start(chunkHandler: chunkHandler)
    }

    func stopDogfoodAudioFileSource() {
        dogfoodAudioFileSource?.stop()
        dogfoodAudioFileSource = nil
    }
}

#endif
