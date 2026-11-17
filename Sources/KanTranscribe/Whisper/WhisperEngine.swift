import CWhisper
import Foundation
import KanCore

struct WhisperDecodeOptions {
    /// ISO 639-1 code; always explicit (whisper.cpp's default is "en", and "auto" detects only once).
    var language: String
    var prompt: String?
    var entropyThreshold: Float
    var threads: Int32
    var beamSize: Int32 = 5
    /// Decoders used on temperature fallback (beam search defaults leave it at -1 = one decoder).
    var bestOf: Int32 = 5
    var noTimestamps = false
}

struct WhisperSegment {
    /// Seconds relative to the decoded samples.
    var range: TimeRange
    var text: String
    var words: [RecognizedWord]
    var noSpeechProbability: Double
    var averageLogProbability: Double
    var meanTokenProbability: Double
    var tokenCount: Int
}

struct WhisperDecodeResult {
    var segments: [WhisperSegment]
    /// The decoder hit its token budget or produced a segment past the end of the audio: text is missing.
    var truncated: Bool
    var seconds: Double
}

/// One loaded whisper.cpp model (Metal) with a single reusable decoder state.
///
/// Thread-safety: not thread-safe. A whisper context/state pair must never be used from two threads
/// at once; the pipeline creates, uses and frees engines only on one `SerialWorker`.
final class WhisperEngine {
    let spec: ModelSpec
    let url: URL
    let loadSeconds: Double
    /// whisper.cpp decodes at most n_text_ctx/2 − 4 tokens per 30 s window (220 for every Whisper size).
    let tokenBudget: Int

    /// `whisper_full_with_state` result when it couldn't grow the decoder's KV cache (beam search
    /// needs one per decoder). whisper.cpp v1.9.5 then frees the caller's state itself
    /// (src/whisper.cpp, "whisper_kv_cache_init() failed for self-attention cache").
    static let stateFreedByWhisper: Int32 = -7

    private let context: OpaquePointer
    /// nil once whisper.cpp has freed it: the engine is unusable and must never touch or free it again.
    private var state: OpaquePointer?

    /// False after whisper.cpp freed the decoder state (out of memory); load the model again.
    var isUsable: Bool { state != nil }

    init(spec: ModelSpec, url: URL, useGPU: Bool) throws {
        WhisperLogging.install()
        var params = whisper_context_default_params()
        params.use_gpu = useGPU
        params.flash_attn = true
        let start = Date()
        guard let context = whisper_init_from_file_with_params_no_state(url.path, params) else {
            throw TranscriptionError.engineFailed("could not load \(spec.displayName) from \(url.lastPathComponent)")
        }
        guard let state = whisper_init_state(context) else {
            whisper_free(context)
            throw TranscriptionError.engineFailed("could not allocate a decoder for \(spec.displayName)")
        }
        self.spec = spec
        self.url = url
        self.context = context
        self.state = state
        tokenBudget = Int(whisper_n_text_ctx(context)) / 2 - 4
        loadSeconds = Date().timeIntervalSince(start)
        KanLog.info("Loaded \(spec.id) (\(String(cString: whisper_model_type_readable(context)))) in "
                    + String(format: "%.2f s", loadSeconds), category: "transcribe")
    }

    deinit {
        if let state { whisper_free_state(state) }
        whisper_free(context)
    }

    private var unusableError: TranscriptionError {
        .engineFailed("\(spec.displayName) ran out of memory and has to be loaded again")
    }

    static func languageID(_ code: String) -> Int? {
        let id = whisper_lang_id(code)
        return id >= 0 ? Int(id) : nil
    }

    static var languageCount: Int { Int(whisper_lang_max_id()) + 1 }

    /// Whisper's probability for every language (index = whisper language id) on these samples.
    func languageProbabilities(_ samples: ArraySlice<Float>, threads: Int32) throws -> [Float] {
        guard let state else { throw unusableError }
        // whisper needs at least 100 ms; pad very short units with silence.
        var padded = Array(samples)
        if padded.count < 1_600 { padded += [Float](repeating: 0, count: 1_600 - padded.count) }
        var probabilities = [Float](repeating: 0, count: Self.languageCount)
        let top: Int32 = padded.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress,
                  whisper_pcm_to_mel_with_state(context, state, base, Int32(buffer.count), threads) == 0
            else { return -100 }
            return whisper_lang_auto_detect_with_state(context, state, 0, threads, &probabilities)
        }
        guard top >= 0 else {
            throw TranscriptionError.engineFailed("language detection failed (\(top))")
        }
        return probabilities
    }

    func decode(_ samples: ArraySlice<Float>, options: WhisperDecodeOptions,
                cancel: CancellationFlag) throws -> WhisperDecodeResult {
        guard let state else { throw unusableError }
        let duration = Double(samples.count) / AudioLoader.sampleRate
        var params = whisper_full_default_params(WHISPER_SAMPLING_BEAM_SEARCH)
        params.n_threads = options.threads
        params.no_context = true
        params.no_timestamps = options.noTimestamps
        params.single_segment = false
        params.print_special = false
        params.print_progress = false
        params.print_realtime = false
        params.print_timestamps = false
        params.token_timestamps = !options.noTimestamps
        params.suppress_blank = true
        params.suppress_nst = true
        params.temperature = 0
        params.temperature_inc = 0.2
        params.entropy_thold = options.entropyThreshold
        params.logprob_thold = -1
        params.no_speech_thold = 0.6
        params.greedy.best_of = options.bestOf
        params.beam_search.beam_size = options.beamSize
        params.detect_language = false
        params.vad = false

        // The flag outlives the call: retained here, released after whisper_full returns.
        let flag = Unmanaged.passRetained(cancel)
        defer { flag.release() }
        params.abort_callback = { userData in
            guard let userData else { return false }
            return Unmanaged<CancellationFlag>.fromOpaque(userData).takeUnretainedValue().isCancelled
        }
        params.abort_callback_user_data = flag.toOpaque()

        let start = Date()
        let rc: Int32 = samples.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return -100 }
            return options.language.withCString { language in
                params.language = language
                guard let prompt = options.prompt, !prompt.isEmpty else {
                    return whisper_full_with_state(context, state, params, base, Int32(buffer.count))
                }
                return prompt.withCString { promptPointer in
                    params.initial_prompt = promptPointer
                    return whisper_full_with_state(context, state, params, base, Int32(buffer.count))
                }
            }
        }
        // Before anything else, even cancellation: `state` is gone and must not be freed again.
        if rc == Self.stateFreedByWhisper { self.state = nil }
        if cancel.isCancelled { throw CancellationError() }
        guard rc == 0 else {
            if rc == Self.stateFreedByWhisper {
                throw TranscriptionError.engineFailed("not enough memory to decode with \(spec.displayName) — "
                                                      + "close other apps or choose a smaller model, then try again")
            }
            throw TranscriptionError.engineFailed("\(spec.id) failed to decode a \(String(format: "%.1f", duration)) s chunk (whisper error \(rc))")
        }
        let (segments, truncated) = collectSegments(state, duration: duration, noTimestamps: options.noTimestamps)
        return WhisperDecodeResult(segments: segments, truncated: truncated, seconds: Date().timeIntervalSince(start))
    }

    private func collectSegments(_ state: OpaquePointer, duration: Double, noTimestamps: Bool) -> ([WhisperSegment], Bool) {
        struct Raw {
            var range: TimeRange
            var pieces: [TokenPiece]
            var noSpeechProbability: Double
            var logProbabilitySum: Double
            var tokenCount: Int
        }
        let endOfText = whisper_token_eot(context)
        var truncated = false
        var raws: [Raw] = []
        for i in 0..<whisper_full_n_segments_from_state(state) {
            let t0 = Double(whisper_full_get_segment_t0_from_state(state, i)) / 100
            let t1 = Double(whisper_full_get_segment_t1_from_state(state, i)) / 100
            let tokenCount = Int(whisper_full_n_tokens_from_state(state, i))
            // Without timestamps whisper.cpp ends every segment at its 30 s window, so only the token
            // budget says anything about truncation there.
            if tokenCount >= tokenBudget || (!noTimestamps && t1 > duration + 1.0) { truncated = true }

            let segmentRange = TimeRange(max(0, t0), min(max(t0, t1), duration))
            var pieces: [TokenPiece] = []
            var logProbabilitySum = 0.0
            var haveTokenTimes = !noTimestamps
            for j in 0..<Int32(tokenCount) {
                let data = whisper_full_get_token_data_from_state(state, i, j)
                guard data.id < endOfText, let text = whisper_full_get_token_text_from_state(context, state, i, j)
                else { continue }
                let bytes = Array(UnsafeBufferPointer(start: UnsafeRawPointer(text).assumingMemoryBound(to: UInt8.self),
                                                      count: strlen(text)))
                if data.t0 < 0 || data.t1 < 0 { haveTokenTimes = false }
                let tokenStart = min(max(Double(data.t0) / 100, segmentRange.start), segmentRange.end)
                let tokenEnd = min(max(Double(data.t1) / 100, tokenStart), segmentRange.end)
                pieces.append(TokenPiece(bytes: bytes, start: tokenStart, end: tokenEnd, probability: Double(data.p)))
                logProbabilitySum += Double(data.plog)
            }
            if !haveTokenTimes { pieces = Self.spreadEvenly(pieces, over: segmentRange) }
            raws.append(Raw(range: segmentRange, pieces: pieces,
                            noSpeechProbability: Double(whisper_full_get_segment_no_speech_prob_from_state(state, i)),
                            logProbabilitySum: logProbabilitySum, tokenCount: tokenCount))
        }

        let repaired = TokenAssembler.repairBoundaries(raws.map(\.pieces))
        var segments: [WhisperSegment] = []
        for (raw, pieces) in zip(raws, repaired) {
            let text = TokenAssembler.text(from: pieces)
            guard !text.isEmpty else { continue }
            let count = Double(max(1, pieces.count))
            segments.append(WhisperSegment(
                range: raw.range, text: text, words: TokenAssembler.words(from: pieces),
                noSpeechProbability: raw.noSpeechProbability, averageLogProbability: raw.logProbabilitySum / count,
                meanTokenProbability: pieces.reduce(0) { $0 + $1.probability } / count, tokenCount: raw.tokenCount))
        }
        return (segments, truncated)
    }

    /// Without token timestamps, spread the segment's time over its tokens by byte length.
    static func spreadEvenly(_ pieces: [TokenPiece], over range: TimeRange) -> [TokenPiece] {
        let total = pieces.reduce(0) { $0 + $1.bytes.count }
        guard total > 0 else { return pieces }
        var cursor = range.start
        return pieces.map { piece in
            var spread = piece
            let length = range.duration * Double(piece.bytes.count) / Double(total)
            spread.start = cursor
            spread.end = min(range.end, cursor + length)
            cursor = spread.end
            return spread
        }
    }
}
