import Foundation

/// A span of time in seconds, `start <= end`.
public struct TimeRange: Hashable, Sendable, Codable, CustomStringConvertible {
    public var start: Double
    public var end: Double

    public init(_ start: Double, _ end: Double) {
        self.start = start
        self.end = max(start, end)
    }

    public var duration: Double { end - start }

    /// Seconds both ranges have in common (0 when disjoint).
    public func overlap(with other: TimeRange) -> Double {
        max(0, min(end, other.end) - max(start, other.start))
    }

    /// Seconds of silence between the ranges (0 when they touch or overlap).
    public func gap(to other: TimeRange) -> Double {
        max(0, max(other.start - end, start - other.end))
    }

    public func contains(_ time: Double) -> Bool { time >= start && time <= end }

    public func clamped(to bounds: TimeRange) -> TimeRange {
        TimeRange(min(max(start, bounds.start), bounds.end), min(max(end, bounds.start), bounds.end))
    }

    public var description: String { String(format: "[%.2f–%.2f]", start, end) }
}

extension Array where Element == Float {
    /// The samples covering `range` at `sampleRate` (clamped to the array).
    func samples(in range: TimeRange, sampleRate: Double = AudioLoader.sampleRate) -> ArraySlice<Float> {
        let lower = Swift.min(count, Swift.max(0, Int((range.start * sampleRate).rounded(.down))))
        let upper = Swift.min(count, Swift.max(lower, Int((range.end * sampleRate).rounded(.up))))
        return self[lower..<upper]
    }
}
