import Foundation

/// Silero speech probabilities, one per 512-sample window (32 ms at 16 kHz).
public struct SpeechProbabilities: Sendable, Equatable {
    public static let windowSamples = 512

    public var values: [Float]
    public var frameDuration: Double

    public init(values: [Float], frameDuration: Double = Double(SpeechProbabilities.windowSamples) / 16_000) {
        self.values = values
        self.frameDuration = frameDuration
    }

    public static let empty = SpeechProbabilities(values: [])

    public func frameIndex(at time: Double) -> Int {
        Int((time / frameDuration).rounded(.down))
    }

    /// Time of the centre of the least speech-like frame whose centre lies in `range`.
    public func quietestTime(in range: TimeRange) -> Double? {
        guard !values.isEmpty, range.duration > 0 else { return nil }
        let first = max(0, Int((range.start / frameDuration - 0.5).rounded(.up)))
        let last = min(values.count - 1, Int((range.end / frameDuration - 0.5).rounded(.down)))
        guard first <= last else { return nil }
        var best = first
        for i in first...last where values[i] < values[best] { best = i }
        return (Double(best) + 0.5) * frameDuration
    }

    /// Mean probability over `range` (0 when not covered).
    public func mean(in range: TimeRange) -> Double {
        guard !values.isEmpty else { return 0 }
        let first = max(0, frameIndex(at: range.start))
        let last = min(values.count - 1, frameIndex(at: max(range.start, range.end - 1e-9)))
        guard first <= last else { return 0 }
        var sum = 0.0
        for i in first...last { sum += Double(values[i]) }
        return sum / Double(last - first + 1)
    }
}

/// Speech segmentation parameters (whisper.cpp / Silero semantics).
public struct VADParameters: Sendable, Equatable {
    public var threshold: Float = 0.5
    public var minSpeechDuration: Double = 0.25
    /// Silence needed to end a segment. 300 ms keeps sentence boundaries; chunks are re-merged later.
    public var minSilenceDuration: Double = 0.3
    public var speechPad: Double = 0.1
    /// Segments closer than this are merged (whisper.cpp always merges < 200 ms gaps).
    public var mergeGap: Double = 0.2

    public init() {}
}

/// Speech segments from Silero probabilities — a port of `whisper_vad_segments_from_probs`
/// (whisper.cpp v1.9.5) without `max_speech_duration_s` (Kan splits long speech itself, at the
/// quietest frame). Pure, so detection can run block by block and stay cancellable.
public enum SpeechSegmenter {
    public static func segments(from probabilities: SpeechProbabilities, parameters: VADParameters = VADParameters(),
                                audioDuration: Double? = nil) -> [TimeRange] {
        let window = SpeechProbabilities.windowSamples
        let sampleRate = Double(window) / probabilities.frameDuration
        let probs = probabilities.values
        guard !probs.isEmpty else { return [] }

        func samples(_ seconds: Double) -> Int { Int(seconds * sampleRate) }
        let minSilence = samples(parameters.minSilenceDuration)
        let minSpeech = samples(parameters.minSpeechDuration)
        let pad = samples(parameters.speechPad)
        let totalSamples = probs.count * window
        let audioSamples = audioDuration.map { min(totalSamples, samples($0)) } ?? totalSamples
        let negativeThreshold = max(0.01, parameters.threshold - 0.15)

        var speeches: [(start: Int, end: Int)] = []
        var inSpeech = false
        var tempEnd = 0
        var speechStart = 0
        for (i, probability) in probs.enumerated() {
            let current = i * window
            if probability >= parameters.threshold && tempEnd != 0 { tempEnd = 0 }
            if probability >= parameters.threshold && !inSpeech {
                inSpeech = true
                speechStart = current
                continue
            }
            if probability < negativeThreshold && inSpeech {
                if tempEnd == 0 { tempEnd = current }
                if current - tempEnd < minSilence { continue }
                if tempEnd - speechStart > minSpeech { speeches.append((speechStart, tempEnd)) }
                tempEnd = 0
                inSpeech = false
            }
        }
        if inSpeech && totalSamples - speechStart > minSpeech { speeches.append((speechStart, totalSamples)) }

        // Merge segments separated by less than `mergeGap`, then drop the ones still too short.
        let mergeGap = samples(parameters.mergeGap)
        var merged: [(start: Int, end: Int)] = []
        for speech in speeches {
            if let last = merged.last, speech.start - last.end < mergeGap {
                merged[merged.count - 1].end = speech.end
            } else {
                merged.append(speech)
            }
        }
        merged.removeAll { $0.end - $0.start < minSpeech }

        // Pad: split the difference when two segments are closer than twice the padding.
        for i in merged.indices {
            if i == 0 { merged[i].start = max(0, merged[i].start - pad) }
            if i < merged.count - 1 {
                let silence = merged[i + 1].start - merged[i].end
                if silence < 2 * pad {
                    merged[i].end += silence / 2
                    merged[i + 1].start = max(0, merged[i + 1].start - silence / 2)
                } else {
                    merged[i].end = min(totalSamples, merged[i].end + pad)
                    merged[i + 1].start = max(0, merged[i + 1].start - pad)
                }
            } else {
                merged[i].end = min(totalSamples, merged[i].end + pad)
            }
        }
        return merged.compactMap { speech in
            let start = Double(min(speech.start, audioSamples)) / sampleRate
            let end = Double(min(speech.end, audioSamples)) / sampleRate
            return end > start ? TimeRange(start, end) : nil
        }
    }
}
