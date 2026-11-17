import Foundation
import KanCore

// Text and time helpers for the app (KanCore keeps its own versions internal).

extension String {
    /// Trimmed, with runs of whitespace and newlines collapsed to single spaces, NFC.
    var kanSingleLine: String {
        split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ").nfc
    }

    /// The trimmed single-line form, or nil when nothing is left.
    var kanNonEmpty: String? {
        let value = kanSingleLine
        return value.isEmpty ? nil : value
    }
}

extension Array where Element == String {
    /// Order-preserving de-duplication ignoring case (the first spelling wins).
    func kanUniquedCaseInsensitive() -> [String] {
        var seen = Set<String>()
        return filter { seen.insert($0.lowercased()).inserted }
    }
}

enum KanFormat {
    /// "14:30" today, "Mon 14:30" this week, "12 Nov, 14:30" otherwise (local time).
    static func shortMoment(_ date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDate(date, inSameDayAs: now) { return time }
        if let days = calendar.dateComponents([.day], from: date, to: now).day, days < 6, date < now {
            return date.formatted(.dateTime.weekday(.abbreviated)) + " " + time
        }
        return date.formatted(.dateTime.day().month(.abbreviated)) + ", " + time
    }

    /// "in 3 min" / "5 min ago" style relative description.
    static func relative(_ date: Date, now: Date = Date()) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: now)
    }

    /// 1_234_567 → "1.2 MB".
    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    /// Seconds as a short duration: "42 min", "45 s".
    static func duration(_ seconds: Double) -> String {
        KanTime.humanDuration(seconds)
    }

    /// Elapsed timer for the menu bar: "4:05", "1:02:05".
    static func timer(_ seconds: Double) -> String {
        KanTime.compact(seconds)
    }

    /// "38%".
    static func percent(_ fraction: Double) -> String {
        "\(Int((min(1, max(0, fraction)) * 100).rounded(.down)))%"
    }
}

extension CallID {
    /// The millisecond timestamp encoded in the first 10 characters of the ULID, or nil when this
    /// isn't a well-formed ULID (used to recognize call-data directories and date orphaned ones).
    var ulidDate: Date? {
        let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
        let chars = Array(rawValue.uppercased())
        guard chars.count == 26 else { return nil }
        var lookup: [Character: UInt64] = [:]
        for (i, c) in alphabet.enumerated() { lookup[c] = UInt64(i) }
        var ms: UInt64 = 0
        for c in chars.prefix(10) {
            guard let v = lookup[c] else { return nil }
            ms = ms << 5 | v
        }
        guard chars.dropFirst(10).allSatisfy({ lookup[$0] != nil }) else { return nil }
        return Date(timeIntervalSince1970: Double(ms) / 1000)
    }
}
