import Foundation
import KanCore

/// Which end of a range a date bounds. A whole day ("2026-11-14", "today") covers everything
/// from its first to its last millisecond, so `--until 2026-11-14` includes calls on the 14th.
public enum DateBound: Sendable {
    case start, end
}

public struct DateInputError: Error, LocalizedError, Equatable, Sendable {
    public let input: String

    public var errorDescription: String? {
        "Unrecognized date “\(input)”. Use YYYY-MM-DD (or YYYY-MM, YYYY), an ISO-8601 time such as "
            + "2026-11-14T10:00:00-05:00 or 2026-11-14T10:00 (local time), “today”, “yesterday”, “now”, "
            + "or an age such as 7d, 12h or 2w."
    }
}

/// Parses the dates accepted by `--since` / `--until` and the MCP `since` / `until` arguments.
///
/// Accepted: `YYYY-MM-DD`, `YYYY-MM`, `YYYY` (whole periods in `timeZone`), ISO-8601 with an offset
/// or `Z` (fractional seconds optional), a local date-time without offset (`2026-11-14T10:00`,
/// `2026-11-14 10:00:30`), `today`, `yesterday`, `now`, and ages: `7d`, `12h`, `2w`, `3 days ago`.
/// Pure and thread-safe.
public struct DateInput: Sendable {
    public var now: Date
    public var timeZone: TimeZone

    public init(now: Date = Date(), timeZone: TimeZone = .current) {
        self.now = now
        self.timeZone = timeZone
    }

    public func parse(_ text: String, as bound: DateBound) throws -> Date {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        guard !trimmed.isEmpty else { throw DateInputError(input: text) }
        let calendar = self.calendar

        switch lower {
        case "now":
            return now
        case "today":
            return try period(calendar.startOfDay(for: now), .day, bound, input: text)
        case "yesterday":
            guard let day = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now)) else {
                throw DateInputError(input: text)
            }
            return try period(day, .day, bound, input: text)
        default:
            break
        }
        if let age = Self.age(lower) {
            return now.addingTimeInterval(-age)
        }
        if let date = try calendarPeriod(lower, bound: bound, input: text) {
            return date
        }
        let isoCandidate = Self.withTSeparator(trimmed)
        if let date = KanDate.parse(isoCandidate) {
            return date
        }
        if let date = localDateTime(isoCandidate) {
            return date
        }
        throw DateInputError(input: text)
    }

    // MARK: - Internals

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    /// "7d", "12h", "2w", "3 days", "3 days ago" → seconds.
    private static func age(_ text: String) -> TimeInterval? {
        var rest = Substring(text)
        if rest.hasSuffix(" ago") { rest = rest.dropLast(4) }
        let digits = rest.prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty, digits.count <= 6, let n = Int(digits) else { return nil }
        let unit = rest.dropFirst(digits.count).trimmingCharacters(in: .whitespaces)
        switch unit {
        case "h", "hr", "hrs", "hour", "hours": return Double(n) * 3600
        case "d", "day", "days": return Double(n) * 86_400
        case "w", "wk", "wks", "week", "weeks": return Double(n) * 7 * 86_400
        default: return nil
        }
    }

    /// "YYYY", "YYYY-MM", "YYYY-MM-DD" → the start or end of that year, month or day.
    private func calendarPeriod(_ text: String, bound: DateBound, input: String) throws -> Date? {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count),
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } }),
              parts[0].count == 4, parts.dropFirst().allSatisfy({ $0.count == 2 }) else { return nil }
        let numbers = parts.compactMap { Int($0) }
        guard numbers.count == parts.count else { return nil }
        var components = DateComponents()
        components.year = numbers[0]
        components.month = numbers.count > 1 ? numbers[1] : 1
        components.day = numbers.count > 2 ? numbers[2] : 1
        let calendar = self.calendar
        // date(from:) rolls 2026-02-30 over to March: reject dates that don't round-trip.
        guard let start = calendar.date(from: components) else { throw DateInputError(input: input) }
        let back = calendar.dateComponents([.year, .month, .day], from: start)
        guard back.year == components.year, back.month == components.month, back.day == components.day else {
            throw DateInputError(input: input)
        }
        let unit: Calendar.Component = numbers.count == 1 ? .year : numbers.count == 2 ? .month : .day
        return try period(start, unit, bound, input: input)
    }

    private func period(_ start: Date, _ unit: Calendar.Component, _ bound: DateBound, input: String) throws -> Date {
        switch bound {
        case .start:
            return start
        case .end:
            guard let next = calendar.date(byAdding: unit, value: 1, to: start) else { throw DateInputError(input: input) }
            // Record dates keep milliseconds: the last millisecond of the period is still inside it.
            return next.addingTimeInterval(-0.001)
        }
    }

    /// "2026-11-14 10:00" → "2026-11-14T10:00" (ISO wants a "T").
    private static func withTSeparator(_ text: String) -> String {
        guard text.count > 11 else { return text }
        let index = text.index(text.startIndex, offsetBy: 10)
        guard text[index] == " " || text[index] == "t" else { return text }
        return text.replacingCharacters(in: index...index, with: "T")
    }

    /// A date-time without an offset, read in `timeZone`.
    private func localDateTime(_ text: String) -> Date? {
        let formats = ["yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ss.SSS"]
        for format in formats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = calendar
            formatter.timeZone = timeZone
            formatter.isLenient = false
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }
}
