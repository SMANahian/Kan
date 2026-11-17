import CWhisper
import Foundation
import KanCore

/// whisper.cpp's standalone Silero VAD (ggml-silero-v6.2.0).
///
/// Thread-safety: not thread-safe; use one detector from one thread at a time.
public final class VoiceActivityDetector {
    private let context: OpaquePointer

    public init(modelURL: URL, threads: Int32 = 4) throws {
        WhisperLogging.install()
        var params = whisper_vad_default_context_params()
        params.n_threads = threads
        params.use_gpu = false
        guard let context = whisper_vad_init_from_file_with_params(modelURL.path, params) else {
            throw TranscriptionError.engineFailed("could not load the voice activity model \(modelURL.lastPathComponent)")
        }
        self.context = context
    }

    deinit { whisper_vad_free(context) }

    /// Speech probability per 32 ms window.
    public func probabilities(_ samples: [Float]) throws -> SpeechProbabilities {
        try probabilities(samples, cancel: CancellationFlag())
    }

    /// Speech probability per 32 ms window. Runs in blocks of about a minute (the LSTM state carries
    /// over between blocks, so the result equals one pass) to check `cancel` and report progress.
    func probabilities(_ samples: [Float], cancel: CancellationFlag,
                       progress: ((Double) -> Void)? = nil) throws -> SpeechProbabilities {
        guard !samples.isEmpty else { return .empty }
        let window = SpeechProbabilities.windowSamples
        let block = window * 1_875
        var values: [Float] = []
        values.reserveCapacity(samples.count / window + 1)
        whisper_vad_reset_state(context)
        var offset = 0
        try samples.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            while offset < buffer.count {
                try cancel.check()
                let count = min(block, buffer.count - offset)
                guard whisper_vad_detect_speech_no_reset(context, base + offset, Int32(count)) else {
                    throw TranscriptionError.engineFailed("voice activity detection failed")
                }
                let produced = Int(whisper_vad_n_probs(context))
                let expected = (count + window - 1) / window
                guard produced == expected, let probs = whisper_vad_probs(context) else {
                    throw TranscriptionError.engineFailed("voice activity detection returned \(produced) frames, expected \(expected)")
                }
                values.append(contentsOf: UnsafeBufferPointer(start: probs, count: produced))
                offset += count
                progress?(Double(offset) / Double(buffer.count))
            }
        }
        return SpeechProbabilities(values: values)
    }
}
