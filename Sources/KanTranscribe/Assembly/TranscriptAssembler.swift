import Foundation
import KanCore

/// A recognized stretch of one track, on the call clock.
public struct RecognizedSegment: Sendable, Hashable {
    public var channel: AudioChannel
    public var range: TimeRange
    public var text: String
    public var language: String
    public var words: [RecognizedWord]
    /// Mean token probability, 0…1.
    public var confidence: Double?
    public var flags: [SegmentFlag]

    public init(channel: AudioChannel, range: TimeRange, text: String, language: String,
                words: [RecognizedWord] = [], confidence: Double? = nil, flags: [SegmentFlag] = []) {
        self.channel = channel
        self.range = range
        self.text = text
        self.language = language
        self.words = words
        self.confidence = confidence
        self.flags = flags
    }
}

/// Builds the final transcript: speakers, word-level speaker assignment on the remote track, echo
/// flags, ordering and ids. Pure.
public enum TranscriptAssembler {
    public struct Input: Sendable {
        public var me: [RecognizedSegment]
        public var them: [RecognizedSegment]
        /// Diarization of the remote track (empty: all remote speech is one speaker).
        public var turns: [SpeakerTurn]
        /// Diarization label → embedding.
        public var embeddings: [String: [Float]]
        public var userName: String
        /// List "me" as a speaker even without segments (the mic was recorded).
        public var includeMe: Bool
        /// Flag mic segments that are loudspeaker echo of the remote side (`EchoDedup`).
        public var flagEchoes: Bool
        /// Call → mic delay of that echo: the echo gate's measurement, else `EchoDedup.unmeasuredLag`.
        public var echoLag: ClosedRange<Double>

        public init(me: [RecognizedSegment], them: [RecognizedSegment], turns: [SpeakerTurn] = [],
                    embeddings: [String: [Float]] = [:], userName: String = "Me", includeMe: Bool = true,
                    flagEchoes: Bool = false, echoLag: ClosedRange<Double> = EchoDedup.unmeasuredLag) {
            self.me = me
            self.them = them
            self.turns = turns
            self.embeddings = embeddings
            self.userName = userName
            self.includeMe = includeMe
            self.flagEchoes = flagEchoes
            self.echoLag = echoLag
        }
    }

    public struct Output: Sendable {
        public var segments: [TranscriptSegment]
        public var speakers: [Speaker]
        public var languages: [String]
        public var speakerEmbeddings: [String: [Float]]
        public var echoSuspects: Int
    }

    /// Label used for remote speech that no diarization turn explains.
    static let unattributed = "unattributed"

    public static func assemble(_ input: Input) -> Output {
        let turns = input.turns.sorted { $0.start < $1.start }
        var remote: [(label: String, segment: RecognizedSegment)] = []
        for segment in input.them {
            for part in splitBySpeaker(segment, turns: turns) {
                remote.append((part.speaker ?? unattributed, part.segment))
            }
        }

        // Remote ids by first appearance: s1, s2, …
        var firstSeen: [String: Double] = [:]
        for (label, segment) in remote { firstSeen[label] = min(firstSeen[label] ?? .infinity, segment.range.start) }
        let orderedLabels = firstSeen.keys.sorted { (firstSeen[$0] ?? 0, $0) < (firstSeen[$1] ?? 0, $1) }
        var idFor: [String: String] = [:]
        for (index, label) in orderedLabels.enumerated() { idFor[label] = "s\(index + 1)" }

        var me = input.me
        var echoCount = 0
        if input.flagEchoes {
            let suspects = EchoDedup.echoSuspects(me: me, them: remote.map(\.segment), lag: input.echoLag)
            for index in suspects where !me[index].flags.contains(.echoSuspect) {
                me[index].flags.append(.echoSuspect)
                echoCount += 1
            }
        }

        var drafts: [(speaker: String, segment: RecognizedSegment)] = me.map { (Speaker.meID, $0) }
        drafts += remote.map { (idFor[$0.label] ?? "s1", $0.segment) }
        let order = drafts.indices.sorted { a, b in
            let x = drafts[a].segment, y = drafts[b].segment
            if x.range.start != y.range.start { return x.range.start < y.range.start }
            if x.range.end != y.range.end { return x.range.end < y.range.end }
            if x.channel != y.channel { return x.channel == .me }
            return a < b
        }
        let segments = order.enumerated().map { id, index -> TranscriptSegment in
            let draft = drafts[index]
            return TranscriptSegment(id: id, start: draft.segment.range.start, end: draft.segment.range.end,
                                     speakerID: draft.speaker, channel: draft.segment.channel,
                                     text: draft.segment.text.nfc, language: draft.segment.language,
                                     confidence: draft.segment.confidence, flags: draft.segment.flags)
        }

        var talkTime: [String: Double] = [:]
        var languageTime: [String: Double] = [:]
        for segment in segments where !segment.flags.contains(.echoSuspect) {
            talkTime[segment.speakerID, default: 0] += segment.end - segment.start
            languageTime[segment.language, default: 0] += segment.end - segment.start
        }
        var speakers: [Speaker] = []
        if input.includeMe || segments.contains(where: { $0.speakerID == Speaker.meID }) {
            speakers.append(Speaker(id: Speaker.meID, name: input.userName, isMe: true, talkTime: talkTime[Speaker.meID] ?? 0))
        }
        for (index, _) in orderedLabels.enumerated() {
            let id = "s\(index + 1)"
            speakers.append(Speaker(id: id, name: Speaker.defaultName(number: index + 1), isMe: false, talkTime: talkTime[id] ?? 0))
        }

        var embeddings: [String: [Float]] = [:]
        for (label, id) in idFor { if let vector = input.embeddings[label] { embeddings[id] = vector } }

        let languages = languageTime.keys.sorted { (-(languageTime[$0] ?? 0), $0) < (-(languageTime[$1] ?? 0), $1) }
        return Output(segments: segments, speakers: speakers, languages: languages, speakerEmbeddings: embeddings,
                      echoSuspects: echoCount)
    }

    // MARK: - Speaker assignment

    /// The diarization label for each word: the turn with the largest overlap; else the nearest turn
    /// within `tolerance` seconds; else the previous word's label (the next one for leading words).
    /// nil only when no word could be placed at all.
    public static func assignSpeakers(_ words: [RecognizedWord], turns: [SpeakerTurn], tolerance: Double = 1.0) -> [String?] {
        guard !turns.isEmpty else { return words.map { _ in nil } }
        let sorted = turns.sorted { $0.start < $1.start }
        let longest = sorted.map { $0.end - $0.start }.max() ?? 0
        var labels: [String?] = words.map { word in
            let range = TimeRange(word.start, max(word.end, word.start + 0.01))
            var low = 0, high = sorted.count
            let earliest = range.start - tolerance - longest
            while low < high {
                let mid = (low + high) / 2
                if sorted[mid].start < earliest { low = mid + 1 } else { high = mid }
            }
            var bestOverlap = 0.0, bestGap = Double.infinity
            var byOverlap: String?, byGap: String?
            var k = low
            while k < sorted.count, sorted[k].start <= range.end + tolerance {
                let turn = sorted[k].range
                let overlap = turn.overlap(with: range)
                if overlap > bestOverlap {
                    bestOverlap = overlap
                    byOverlap = sorted[k].speaker
                }
                let gap = turn.gap(to: range)
                if gap <= tolerance && gap < bestGap {
                    bestGap = gap
                    byGap = sorted[k].speaker
                }
                k += 1
            }
            return byOverlap ?? byGap
        }
        var previous: String?
        for index in labels.indices {
            if let label = labels[index] { previous = label } else { labels[index] = previous }
        }
        if let firstKnown = labels.first(where: { $0 != nil }) {
            for index in labels.indices where labels[index] == nil { labels[index] = firstKnown }
        }
        return labels
    }

    /// Splits a remote segment wherever the speaker changes between words. A lone word under 0.5 s
    /// between two words of the same other speaker is treated as boundary jitter.
    public static func splitBySpeaker(_ segment: RecognizedSegment, turns: [SpeakerTurn])
        -> [(speaker: String?, segment: RecognizedSegment)] {
        guard !turns.isEmpty else { return [(nil, segment)] }
        guard !segment.words.isEmpty else { return [(nearestSpeaker(to: segment.range, turns: turns), segment)] }
        var labels = assignSpeakers(segment.words, turns: turns)
        if labels.allSatisfy({ $0 == nil }) {
            let nearest = nearestSpeaker(to: segment.range, turns: turns)
            labels = labels.map { _ in nearest }
        }
        if labels.count >= 3 {
            for i in 1..<(labels.count - 1) where labels[i] != labels[i - 1] && labels[i - 1] == labels[i + 1]
                && segment.words[i].end - segment.words[i].start < 0.5 {
                labels[i] = labels[i - 1]
            }
        }
        var groups: [(label: String?, words: [RecognizedWord])] = []
        for (word, label) in zip(segment.words, labels) {
            if let last = groups.last, last.label == label {
                groups[groups.count - 1].words.append(word)
            } else {
                groups.append((label, [word]))
            }
        }
        guard groups.count > 1 else { return [(labels.first ?? nil, segment)] }
        return groups.enumerated().map { index, group in
            let start = index == 0 ? segment.range.start : (group.words.first?.start ?? segment.range.start)
            let end = index == groups.count - 1 ? segment.range.end : (group.words.last?.end ?? segment.range.end)
            let confidence = group.words.reduce(0) { $0 + $1.probability } / Double(group.words.count)
            var part = segment
            part.range = TimeRange(start, max(start, end))
            part.words = group.words
            part.text = TextPostProcessor.clean(group.words.map(\.text).joined(separator: " "))
            part.confidence = confidence
            return (group.label, part)
        }
    }

    /// The turn overlapping `range` most, else the closest one in time.
    public static func nearestSpeaker(to range: TimeRange, turns: [SpeakerTurn]) -> String? {
        if let best = turns.max(by: { $0.range.overlap(with: range) < $1.range.overlap(with: range) }),
           best.range.overlap(with: range) > 0 {
            return best.speaker
        }
        return turns.min { $0.range.gap(to: range) < $1.range.gap(to: range) }?.speaker
    }
}
