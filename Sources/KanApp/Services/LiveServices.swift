import Foundation
import KanAI
import KanAudio
import KanCore
import KanDetect
import KanTranscribe

/// The real services: Core Audio capture and detection, whisper.cpp + FluidAudio transcription,
/// OpenAI (opt-in) with the API key in the login keychain.
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
            assistant: OpenAIAssistant(),
            apiKeys: KeychainAPIKeyStore(),
            isMock: false)
    }
}
