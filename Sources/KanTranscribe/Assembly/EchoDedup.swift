import Foundation

/// Finds microphone segments that are loudspeaker echo of the remote side which survived the audio
/// gate. Pure.
///
/// An echo is the remote audio played back into the mic a little later (the call → mic lag), so a
/// mic segment is a suspect only when both hold:
///  - **time:** it lies (almost) entirely within remote speech delayed by the lag, and
///  - **text:** what it says is mostly contained in what the remote side said at that moment —
///    measured in the mic text's direction, because an echo is often a fragment of the clean
///    far-end segment but never says more than it.
/// Repeating the other person's words to agree ("Yes, I think that would help") follows their turn
/// instead of coinciding with it, and a long turn that contains a phrase the other side then
/// repeats isn't contained in that phrase, so neither is flagged. Character trigrams work for
/// Bangla, English and mixed text.
public enum EchoDedup {
    /// Texts with fewer distinct trigrams ("okay", "হ্যাঁ") can't be judged by text alone.
    public static let minimumTrigrams = 8

    /// Call → mic delays considered when the echo gate couldn't measure one: built-in speakers add
    /// tens of milliseconds, Bluetooth and HDMI a few hundred. Longer routes (AirPlay buffers up to
    /// ~2 s) still match long segments; a wider window would also catch replies right after a turn.
    public static let unmeasuredLag: ClosedRange<Double> = 0...1.0

    /// |A ∩ B| / min(|A|, |B|) over character trigrams of the normalized texts, 0 when either text
    /// has fewer than `minimumTrigrams`. Symmetric: high when either text is (mostly) part of the
    /// other, e.g. a decode that repeats its prompt.
    public static func similarity(_ a: String, _ b: String) -> Double {
        let x = trigrams(a), y = trigrams(b)
        guard x.count >= minimumTrigrams, y.count >= minimumTrigrams else { return 0 }
        return Double(x.intersection(y).count) / Double(min(x.count, y.count))
    }

    /// Share of the trigrams of `text` that also occur in `source` (1: everything `text` says, `source`
    /// says too), 0 when either text has fewer than `minimumTrigrams`.
    public static func containment(of text: String, in source: String) -> Double {
        containment(trigrams(text), in: trigrams(source))
    }

    /// Indices into `me` of segments that are echo of `them` (both on the call clock).
    ///
    /// - Parameters:
    ///   - lag: possible call → mic delays in seconds; a single value when the echo gate measured it.
    ///   - tolerance: timing slack in seconds for segment edges (VAD padding, recognizer timestamps,
    ///     reverberation tails).
    ///   - minimumCoverage: share of the mic segment's time that must fall inside delayed remote speech.
    ///   - threshold: share of the mic segment's trigrams that the remote side must have said then.
    public static func echoSuspects(me: [RecognizedSegment], them: [RecognizedSegment],
                                    lag: ClosedRange<Double> = unmeasuredLag, tolerance: Double = 0.5,
                                    minimumCoverage: Double = 0.8, threshold: Double = 0.5) -> [Int] {
        guard !me.isEmpty, !them.isEmpty else { return [] }
        let remote = them.sorted { $0.range.start < $1.range.start }
        // The longest remote segment bounds how far before a window a segment overlapping it can start.
        let longest = remote.map(\.range.duration).max() ?? 0
        var suspects: [Int] = []
        for (index, segment) in me.enumerated() {
            let grams = trigrams(segment.text)
            guard grams.count >= minimumTrigrams else { continue }
            // Where on the call clock audio heard during this segment could have been played.
            let source = TimeRange(segment.range.start - lag.upperBound - tolerance,
                                   segment.range.end - lag.lowerBound + tolerance)
            var low = 0, high = remote.count
            let earliest = source.start - longest
            while low < high {
                let mid = (low + high) / 2
                if remote[mid].range.start < earliest { low = mid + 1 } else { high = mid }
            }
            var played: [TimeRange] = []   // remote speech as the mic could hear it
            var words: [String] = []       // what the remote side said during `source`
            var k = low
            while k < remote.count, remote[k].range.start <= source.end {
                let candidate = remote[k]
                k += 1
                guard candidate.range.end >= source.start else { continue }
                played.append(TimeRange(candidate.range.start + lag.lowerBound - tolerance,
                                        candidate.range.end + lag.upperBound + tolerance))
                if candidate.words.isEmpty {
                    words.append(candidate.text)
                } else {
                    words += candidate.words.filter { $0.end >= source.start && $0.start <= source.end }.map(\.text)
                }
            }
            guard !played.isEmpty, coverage(of: segment.range, by: played) >= minimumCoverage else { continue }
            if containment(grams, in: trigrams(words.joined(separator: " "))) >= threshold {
                suspects.append(index)
            }
        }
        return suspects
    }

    /// Share of `range` inside the union of `windows` (sorted by start); for an instant, 1 when a
    /// window contains it.
    static func coverage(of range: TimeRange, by windows: [TimeRange]) -> Double {
        guard range.duration > 0 else { return windows.contains { $0.contains(range.start) } ? 1 : 0 }
        var covered = 0.0
        var current: TimeRange?
        for window in windows {
            if let open = current, window.start <= open.end {
                current = TimeRange(open.start, max(open.end, window.end))
            } else {
                if let open = current { covered += open.overlap(with: range) }
                current = window
            }
        }
        if let open = current { covered += open.overlap(with: range) }
        return covered / range.duration
    }

    static func trigrams(_ text: String) -> Set<String> {
        let characters = Array(text.lowercased().filter { $0.isLetter || $0.isNumber || $0 == " " })
        guard characters.count >= 3 else { return [] }
        return Set((0...(characters.count - 3)).map { String(characters[$0..<($0 + 3)]) })
    }

    static func containment(_ text: Set<String>, in source: Set<String>) -> Double {
        guard text.count >= minimumTrigrams, source.count >= minimumTrigrams else { return 0 }
        return Double(text.intersection(source).count) / Double(text.count)
    }
}
