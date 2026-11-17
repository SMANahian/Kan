import Foundation
import KanCore

/// Per-speaker numbers for the speakers bar. Pure and thread-safe.
enum LibrarySpeakerStats {
    /// Share of talk time per speaker id (0…1, summing to 1). Uses `Speaker.talkTime` when the
    /// transcriber recorded it, otherwise the durations of the speaker's segments with text (echo
    /// suspects excluded). Empty when nobody spoke.
    static func talkShares(speakers: [Speaker], segments: [TranscriptSegment]) -> [String: Double] {
        var seconds: [String: Double] = [:]
        let recorded = speakers.reduce(0) { $0 + max(0, $1.talkTime) }
        if recorded > 0 {
            for speaker in speakers { seconds[speaker.id, default: 0] += max(0, speaker.talkTime) }
        } else {
            for segment in segments where !segment.flags.contains(.echoSuspect)
                && !LibraryTextMatch.singleLine(segment.text).isEmpty {
                seconds[segment.speakerID, default: 0] += max(0, segment.end - segment.start)
            }
        }
        let total = seconds.values.reduce(0, +)
        guard total > 0 else { return [:] }
        return seconds.mapValues { $0 / total }
    }

    /// The speaker's longest segment with text that isn't an echo suspect (earliest on ties): the
    /// cleanest place to hear their voice.
    static func sampleSegment(for speakerID: String, in segments: [TranscriptSegment]) -> TranscriptSegment? {
        var best: TranscriptSegment?
        for segment in segments where segment.speakerID == speakerID && !segment.flags.contains(.echoSuspect)
            && !LibraryTextMatch.singleLine(segment.text).isEmpty {
            let length = segment.end - segment.start
            guard length > 0 else { continue }
            if let current = best {
                let currentLength = current.end - current.start
                if length > currentLength || (length == currentLength && segment.start < current.start) { best = segment }
            } else {
                best = segment
            }
        }
        return best
    }

    /// Palette slot per speaker id: 0 for the user ("me"), then 1, 2, … for the others in speaker
    /// order, cycling through slots 1..<slotCount. Stable for a call as long as its speakers are.
    static func colorSlots(speakers: [Speaker], slotCount: Int) -> [String: Int] {
        guard slotCount > 1 else { return Dictionary(speakers.map { ($0.id, 0) }, uniquingKeysWith: { a, _ in a }) }
        var slots: [String: Int] = [:]
        var next = 0
        for speaker in speakers where slots[speaker.id] == nil {
            if speaker.isMe || speaker.id == Speaker.meID {
                slots[speaker.id] = 0
            } else {
                slots[speaker.id] = 1 + next % (slotCount - 1)
                next += 1
            }
        }
        return slots
    }

    /// Speakers in display order: the user first, then the others in their order.
    static func displayOrder(_ speakers: [Speaker]) -> [Speaker] {
        speakers.filter(\.isMe) + speakers.filter { !$0.isMe }
    }

    /// The other speaker in this call already called `name` (ignoring case), if any — naming a speaker
    /// like that merges the two.
    static func speaker(named name: String, in speakers: [Speaker], excluding id: String) -> Speaker? {
        let key = LibraryFilter.nameKey(name)
        guard !key.isEmpty else { return nil }
        return speakers.first { $0.id != id && LibraryFilter.nameKey($0.name) == key }
    }
}
