import Foundation
import KanAudio
import KanCore
import KanDetect
import KanTranscribe

/// The real services: Core Audio capture and detection, whisper.cpp + FluidAudio transcription.
enum LiveServices {
    static func make() -> KanServices? {
        let models = ModelStore()
        return KanServices(
            detector: CallDetector(),
            recorder: CallRecorder(),
            transcriber: TranscriptionPipeline(models: models),
            models: models,
            permissions: Permissions(),
            archiver: AudioArchiver(),
            isMock: false)
    }
}
