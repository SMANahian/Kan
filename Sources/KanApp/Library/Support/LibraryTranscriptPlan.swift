import Foundation
import KanCore

/// One speaker turn of the reader: consecutive segments of the same speaker.
struct LibraryTranscriptTurn: Equatable, Identifiable {
    /// The first segment's id.
    let id: Int
    let speakerID: String
    let start: Double
    let end: Double
    let segments: [TranscriptSegment]
}

/// Merges segments into turns, the way the Markdown transcript does (KanCore's TranscriptLayout):
/// consecutive segments of one speaker less than 2 s apart form a turn, up to 90 s long.
enum LibraryTurnMerging {
    static let maxGap: Double = 2
    static let maxTurnSeconds: Double = 90

    /// Segments with text, sorted by start (stable: edits may have appended segments out of order).
    /// Echo suspects (mic bleed of the other side) are left out unless `includeEchoSuspects`.
    static func visibleSegments(_ segments: [TranscriptSegment], includeEchoSuspects: Bool) -> [TranscriptSegment] {
        segments.enumerated()
            .filter { _, segment in
                (includeEchoSuspects || !segment.flags.contains(.echoSuspect))
                    && !LibraryTextMatch.singleLine(segment.text).isEmpty
            }
            .sorted { a, b in a.element.start != b.element.start ? a.element.start < b.element.start : a.offset < b.offset }
            .map(\.element)
    }

    static func turns(_ segments: [TranscriptSegment], includeEchoSuspects: Bool) -> [LibraryTranscriptTurn] {
        var turns: [LibraryTranscriptTurn] = []
        var current: [TranscriptSegment] = []
        var start = 0.0, end = 0.0
        func flush() {
            guard let first = current.first else { return }
            turns.append(LibraryTranscriptTurn(id: first.id, speakerID: first.speakerID, start: start, end: end, segments: current))
            current = []
        }
        for segment in visibleSegments(segments, includeEchoSuspects: includeEchoSuspects) {
            if let first = current.first, first.speakerID == segment.speakerID,
               segment.start - end < maxGap, segment.end - start <= maxTurnSeconds {
                current.append(segment)
                end = max(end, segment.end)
            } else {
                flush()
                current = [segment]
                start = segment.start
                end = segment.end
            }
        }
        flush()
        return turns
    }

    /// Segments with text flagged as possible echo (hidden by default).
    static func echoSuspectCount(_ segments: [TranscriptSegment]) -> Int {
        segments.filter { $0.flags.contains(.echoSuspect) && !LibraryTextMatch.singleLine($0.text).isEmpty }.count
    }
}

/// The reader's text without styling: per turn a header line ("Name  [00:01:23]") and a paragraph of
/// its segments, with the UTF-16 ranges AppKit needs to style, hit-test and highlight it, and
/// lookups from playback time to segment. Pure and thread-safe (a value).
struct LibraryTranscriptPlan: Equatable {
    struct Turn: Equatable {
        let turn: LibraryTranscriptTurn
        let speakerName: String
        let headerRange: NSRange
        let nameRange: NSRange
        let timeRange: NSRange
        let bodyRange: NSRange
    }

    struct Segment: Equatable {
        let segment: TranscriptSegment
        /// The segment's text in `string`.
        let range: NSRange
        let turnIndex: Int
        let isEchoSuspect: Bool
        /// The single-line text shown.
        let text: String
    }

    let string: String
    let turns: [Turn]
    /// In reading order (sorted by start time).
    let segments: [Segment]

    var isEmpty: Bool { segments.isEmpty }

    static let empty = LibraryTranscriptPlan(string: "", turns: [], segments: [])

    private init(string: String, turns: [Turn], segments: [Segment]) {
        self.string = string
        self.turns = turns
        self.segments = segments
    }

    /// - Parameter speakerName: display name for a speaker id (`CallRecord.speakerName`).
    init(segments allSegments: [TranscriptSegment], includeEchoSuspects: Bool, speakerName: (String) -> String) {
        var string = ""
        var length = 0
        var turns: [Turn] = []
        var segments: [Segment] = []
        func append(_ piece: String) -> NSRange {
            let range = NSRange(location: length, length: piece.utf16.count)
            string += piece
            length += range.length
            return range
        }
        for turn in LibraryTurnMerging.turns(allSegments, includeEchoSuspects: includeEchoSuspects) {
            let name = LibraryTextMatch.singleLine(speakerName(turn.speakerID))
            let nameRange = append(name.isEmpty ? " " : name)
            _ = append("  ")
            let timeRange = append("[\(KanTime.hms(turn.start))]")
            _ = append("\n")
            let headerRange = NSRange(location: nameRange.location, length: timeRange.upperBound - nameRange.location)
            let bodyStart = length
            for (i, segment) in turn.segments.enumerated() {
                if i > 0 { _ = append(" ") }
                let text = LibraryTextMatch.singleLine(segment.text.precomposedStringWithCanonicalMapping)
                segments.append(Segment(segment: segment, range: append(text), turnIndex: turns.count,
                                        isEchoSuspect: segment.flags.contains(.echoSuspect), text: text))
            }
            let bodyRange = NSRange(location: bodyStart, length: length - bodyStart)
            _ = append("\n")
            turns.append(Turn(turn: turn, speakerName: name, headerRange: headerRange, nameRange: nameRange,
                              timeRange: timeRange, bodyRange: bodyRange))
        }
        self.init(string: string, turns: turns, segments: segments)
    }

    // MARK: Lookups

    /// The segment being heard at `time`: the last one started at or before `time`, while playback
    /// is inside it or less than 2 s past its end (so short pauses don't flicker the highlight).
    func segmentIndex(playingAt time: Double) -> Int? {
        guard let index = lastSegmentIndex(startingAtOrBefore: time) else { return nil }
        return time - segments[index].segment.end < LibraryTurnMerging.maxGap ? index : nil
    }

    /// Where to scroll for `time`: the last segment started at or before it (or the first segment).
    func segmentIndex(nearest time: Double) -> Int? {
        guard !segments.isEmpty else { return nil }
        return lastSegmentIndex(startingAtOrBefore: time) ?? 0
    }

    func segmentIndex(forID id: Int) -> Int? {
        segments.firstIndex { $0.segment.id == id }
    }

    /// The segment whose text contains the UTF-16 offset `location`.
    func segmentIndex(containing location: Int) -> Int? {
        var low = 0, high = segments.count - 1
        while low <= high {
            let mid = (low + high) / 2
            let range = segments[mid].range
            if location < range.location {
                high = mid - 1
            } else if location >= range.upperBound {
                low = mid + 1
            } else {
                return mid
            }
        }
        return nil
    }

    /// Ranges in `string` of every occurrence of the terms, inside segment texts only (names and
    /// timestamps don't match), in reading order.
    func matchRanges(of terms: [String]) -> [NSRange] {
        guard !terms.isEmpty else { return [] }
        var out: [NSRange] = []
        for segment in segments {
            for range in LibraryTextMatch.nsRanges(of: terms, in: segment.text) {
                out.append(NSRange(location: segment.range.location + range.location, length: range.length))
            }
        }
        return out
    }

    private func lastSegmentIndex(startingAtOrBefore time: Double) -> Int? {
        var low = 0, high = segments.count - 1
        var found: Int?
        while low <= high {
            let mid = (low + high) / 2
            if segments[mid].segment.start <= time {
                found = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return found
    }
}
