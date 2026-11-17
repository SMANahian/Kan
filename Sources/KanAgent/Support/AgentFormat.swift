import Foundation
import KanCore

/// Date and text formatting shared by the CLI and the MCP server. Thread-safe.
public enum AgentFormat {
    /// The call's time zone, or the current one when the identifier is unknown.
    public static func timeZone(_ identifier: String) -> TimeZone {
        TimeZone(identifier: identifier) ?? .current
    }

    /// ISO-8601 with the UTC offset of `timeZone`, whole seconds: "2026-11-14T10:00:12-05:00".
    public static func isoDate(_ date: Date, timeZone identifier: String) -> String {
        formatter(for: identifier).string(from: date)
    }

    /// "2026-11-14 10:00" in the call's own time zone (as in the library's file names).
    public static func shortDate(_ date: Date, timeZone identifier: String) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone(identifier)
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return String(format: "%04d-%02d-%02d %02d:%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0)
    }

    /// "-05:00" (or "+06:00") for `date` in the zone.
    public static func utcOffset(_ date: Date, timeZone identifier: String) -> String {
        let seconds = timeZone(identifier).secondsFromGMT(for: date)
        let sign = seconds < 0 ? "-" : "+"
        let minutes = abs(seconds) / 60
        return String(format: "%@%02d:%02d", sign, minutes / 60, minutes % 60)
    }

    /// Whole seconds as an Int, clamped (a damaged record's dates must not trap the conversion).
    static func wholeSeconds(_ value: Double) -> Int {
        guard value.isFinite else { return 0 }
        return Int(min(max(value.rounded(), -1e15), 1e15))
    }

    /// "1 segment", "3 segments".
    static func count(_ n: Int, _ singular: String, _ plural: String? = nil) -> String {
        "\(n) " + (n == 1 ? singular : plural ?? singular + "s")
    }

    /// Rounded to three decimals (milliseconds for times), so JSON shows 12.5 rather than 12.499999999.
    static func rounded(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return (value * 1000).rounded() / 1000
    }

    // MARK: - Formatter cache

    private static let lock = NSLock()
    nonisolated(unsafe) private static var formatters: [String: ISO8601DateFormatter] = [:]

    private static func formatter(for identifier: String) -> ISO8601DateFormatter {
        lock.lock()
        defer { lock.unlock() }
        if let cached = formatters[identifier] { return cached }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = timeZone(identifier)
        if formatters.count > 64 { formatters.removeAll() }
        formatters[identifier] = formatter
        return formatter
    }
}

extension String {
    /// Whitespace runs (newlines included) collapsed to one space, trimmed.
    var singleLineText: String {
        var out = ""
        var pendingSpace = false
        for character in self {
            if character.isWhitespace || character.isNewline {
                pendingSpace = !out.isEmpty
            } else {
                if pendingSpace {
                    out.append(" ")
                    pendingSpace = false
                }
                out.append(character)
            }
        }
        return out
    }

    /// Columns the text takes in a terminal (see `Character.displayWidth`). An estimate: terminals
    /// differ, but this is what wcwidth-based ones (Terminal, iTerm2) do.
    var displayWidth: Int {
        var width = 0
        for character in self { width += character.displayWidth }
        return width
    }

    /// The text cut to at most `width` columns, ending in "…" when cut. Never splits a character.
    func truncated(toWidth width: Int) -> String {
        guard width > 0 else { return "" }
        guard displayWidth > width else { return self }
        var out = ""
        var used = 0
        for character in self {
            let w = character.displayWidth
            if used + w > width - 1 { break }
            out.append(character)
            used += w
        }
        return out.trimmingCharacters(in: .whitespaces) + "…"
    }

    /// The text followed by spaces up to `width` columns.
    func padded(toWidth width: Int) -> String {
        let w = displayWidth
        return w >= width ? self : self + String(repeating: " ", count: width - w)
    }

    /// The text preceded by spaces up to `width` columns.
    func leftPadded(toWidth width: Int) -> String {
        let w = displayWidth
        return w >= width ? self : String(repeating: " ", count: width - w) + self
    }
}

extension Character {
    /// wcwidth-style: nonspacing and enclosing marks, format characters and variation selectors take
    /// no cell (Bangla ্ ু ি… are Mn; া ে ো are spacing marks and take one), wide East Asian
    /// characters and emoji take two, everything else one.
    var displayWidth: Int {
        if unicodeScalars.contains(where: { $0.properties.isEmojiPresentation }) { return 2 }
        var width = 0
        for scalar in unicodeScalars {
            switch scalar.properties.generalCategory {
            case .nonspacingMark, .enclosingMark, .format, .control:
                continue
            default:
                if (0xFE00...0xFE0F).contains(scalar.value) { continue }
                width += Self.isWide(scalar.value) ? 2 : 1
            }
        }
        return width
    }

    private static func isWide(_ v: UInt32) -> Bool {
        (v >= 0x1100 && v <= 0x115F) || (v >= 0x2E80 && v <= 0x303E) || (v >= 0x3041 && v <= 0x33FF)
            || (v >= 0x3400 && v <= 0x4DBF) || (v >= 0x4E00 && v <= 0x9FFF) || (v >= 0xA000 && v <= 0xA4CF)
            || (v >= 0xAC00 && v <= 0xD7A3) || (v >= 0xF900 && v <= 0xFAFF) || (v >= 0xFE30 && v <= 0xFE4F)
            || (v >= 0xFF00 && v <= 0xFF60) || (v >= 0xFFE0 && v <= 0xFFE6) || (v >= 0x20000 && v <= 0x3FFFD)
    }
}
