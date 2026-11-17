import Foundation

/// Length limits for language-ID units and decode chunks.
///
/// Whisper decodes at most ~220 tokens per window. Bangla costs ~22 tokens per second of speech with
/// the stock tokenizer (so ≤ 8 s or text is silently lost) and ~8 with the Bengali.AI tokenizer
/// (≤ 15 s); English costs ~3.5 (≤ 25 s; long English chunks also avoid mid-sentence cuts).
public struct ChunkLimits: Sendable, Equatable {
    public var languageUnitMax: Double = 15
    public var englishMax: Double = 25
    public var banglaMax: Double = 8
    /// Consecutive same-language units this close are decoded together.
    public var mergeGap: Double = 1.5

    public init(banglaTokenizer: Bool) {
        banglaMax = banglaTokenizer ? 15 : 8
    }

    public func maxLength(for language: String) -> Double {
        language == "bn" ? banglaMax : englishMax
    }
}

/// A stretch of speech with its routed language (and, on the remote track, its diarized speaker).
public struct LanguageUnit: Sendable, Hashable {
    public var range: TimeRange
    public var language: String
    /// Units of different speakers are never decoded together.
    public var speaker: String?

    public init(range: TimeRange, language: String, speaker: String? = nil) {
        self.range = range
        self.language = language
        self.speaker = speaker
    }
}

/// Audio handed to the recognizer in one call.
public struct DecodeChunk: Sendable, Hashable {
    public var range: TimeRange
    public var language: String

    public init(range: TimeRange, language: String) {
        self.range = range
        self.language = language
    }
}

/// Plans language-ID units and decode chunks from VAD output. Pure.
public enum ChunkPlanner {
    /// Splits every range longer than `maxLength` at the quietest VAD frame between 0.5× and 1× the
    /// maximum from the current start (a pause between words or sentences, when there is one).
    public static func split(_ ranges: [TimeRange], probabilities: SpeechProbabilities,
                             maxLength: Double) -> [TimeRange] {
        guard maxLength > 0 else { return ranges }
        var result: [TimeRange] = []
        for range in ranges {
            var start = range.start
            while range.end - start > maxLength {
                let window = TimeRange(start + 0.5 * maxLength, start + maxLength)
                var cut = probabilities.quietestTime(in: window) ?? window.end
                if cut <= start || cut >= range.end { cut = window.end }
                result.append(TimeRange(start, cut))
                start = cut
            }
            result.append(TimeRange(start, range.end))
        }
        return result
    }

    /// Language-ID units: VAD speech cut to at most `limits.languageUnitMax`.
    public static func languageUnits(speech: [TimeRange], probabilities: SpeechProbabilities,
                                     limits: ChunkLimits) -> [TimeRange] {
        split(speech.sorted { $0.start < $1.start }, probabilities: probabilities, maxLength: limits.languageUnitMax)
    }

    /// Decode chunks: consecutive units of the same language with gaps ≤ `limits.mergeGap` are merged
    /// while the chunk stays within its language's cap; units longer than the cap are split.
    public static func decodeChunks(units: [LanguageUnit], probabilities: SpeechProbabilities,
                                    limits: ChunkLimits) -> [DecodeChunk] {
        var chunks: [DecodeChunk] = []
        var lastSpeaker: String?
        for unit in units.sorted(by: { $0.range.start < $1.range.start }) {
            defer { lastSpeaker = unit.speaker }
            let cap = limits.maxLength(for: unit.language)
            if var last = chunks.last, last.language == unit.language, lastSpeaker == unit.speaker,
               unit.range.start - last.range.end <= limits.mergeGap,
               unit.range.end - last.range.start <= cap {
                last.range = TimeRange(last.range.start, max(last.range.end, unit.range.end))
                chunks[chunks.count - 1] = last
            } else {
                chunks.append(DecodeChunk(range: unit.range, language: unit.language))
            }
        }
        return chunks.flatMap { chunk -> [DecodeChunk] in
            let cap = limits.maxLength(for: chunk.language)
            guard chunk.range.duration > cap else { return [chunk] }
            return split([chunk.range], probabilities: probabilities, maxLength: cap)
                .map { DecodeChunk(range: $0, language: chunk.language) }
        }
    }

    /// Where the main speaker changes, from diarization turns: a short turn lying inside another
    /// speaker's turn (a backchannel) is not a change; overlapping hand-overs change at the middle of
    /// the overlap, others in the middle of the pause.
    public static func speakerChangePoints(_ turns: [SpeakerTurn]) -> [Double] {
        var primary: [SpeakerTurn] = []
        for turn in turns.sorted(by: { $0.start < $1.start }) where turn.end > turn.start {
            if let last = primary.last {
                if turn.speaker == last.speaker {
                    primary[primary.count - 1].end = max(last.end, turn.end)
                    continue
                }
                if turn.end <= last.end { continue }
            }
            primary.append(turn)
        }
        return zip(primary, primary.dropFirst()).map { a, b in (a.end + b.start) / 2 }
    }

    /// Cuts ranges at `points` that lie at least `minimumPiece` inside them.
    public static func cut(_ ranges: [TimeRange], at points: [Double], minimumPiece: Double = 0.4) -> [TimeRange] {
        let sortedPoints = points.sorted()
        return ranges.flatMap { range -> [TimeRange] in
            var pieces: [TimeRange] = []
            var start = range.start
            for point in sortedPoints where point - start >= minimumPiece && range.end - point >= minimumPiece {
                pieces.append(TimeRange(start, point))
                start = point
            }
            pieces.append(TimeRange(start, range.end))
            return pieces
        }
    }

    /// Two halves for a retry after truncation, cut at the quietest frame in the middle 40 %;
    /// nil when the range is too short to split usefully.
    public static func halve(_ range: TimeRange, probabilities: SpeechProbabilities,
                             minimumLength: Double = 1.0) -> (TimeRange, TimeRange)? {
        guard range.duration >= 2 * minimumLength else { return nil }
        let middle = TimeRange(range.start + 0.3 * range.duration, range.end - 0.3 * range.duration)
        var cut = probabilities.quietestTime(in: middle) ?? (range.start + range.duration / 2)
        cut = min(max(cut, range.start + minimumLength), range.end - minimumLength)
        return (TimeRange(range.start, cut), TimeRange(cut, range.end))
    }
}
