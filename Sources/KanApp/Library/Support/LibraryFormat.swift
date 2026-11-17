import Foundation
import KanCore

/// Display strings of the library window, in the viewer's locale and time zone. Pure and thread-safe.
enum LibraryFormat {
    /// "10:00–10:42"; the end gets its date when the call ran past midnight.
    static func timeRange(_ start: Date, _ end: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        let time = Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, calendar: calendar,
                                    timeZone: calendar.timeZone)
        let startText = start.formatted(time)
        guard end > start else { return startText }
        if calendar.isDate(start, inSameDayAs: end) { return "\(startText)–\(end.formatted(time))" }
        let dated = Date.FormatStyle(date: .abbreviated, time: .shortened, locale: locale, calendar: calendar,
                                     timeZone: calendar.timeZone)
        return "\(startText)–\(end.formatted(dated))"
    }

    /// "Friday 14 November 2026" (weekday + full date).
    static func longDate(_ date: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        date.formatted(Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
            .weekday(.wide).day().month(.wide).year())
    }

    /// "বাংলা" for bn, "English" for en, otherwise the localized language name (or the code).
    static func languageName(_ code: String, locale: Locale = .current) -> String {
        switch code.lowercased() {
        case "bn": return "বাংলা"
        case "en": return "English"
        default: return locale.localizedString(forLanguageCode: code) ?? code
        }
    }

    static func languages(_ codes: [String]) -> String {
        codes.map { languageName($0) }.joined(separator: ", ")
    }

    /// 0.523 → "52%".
    static func percent(_ fraction: Double) -> String {
        "\(Int((min(1, max(0, fraction)) * 100).rounded()))%"
    }

    /// "Zoom", "Telegram", or "Google Meet (Zen)" for a meeting platform used through another app
    /// (the same label the Markdown header uses).
    static func appLabel(appName: String, platform: CallPlatform) -> String {
        let trimmed = LibraryTextMatch.singleLine(appName)
        let app = trimmed.isEmpty ? platform.displayName : trimmed
        switch platform {
        case .browser, .manual, .imported, .other:
            return app
        default:
            let name = platform.displayName
            if name.caseInsensitiveCompare(app) == .orderedSame || app.localizedCaseInsensitiveContains(name) {
                return app
            }
            return "\(name) (\(app))"
        }
    }

    /// "12 calls", "1 call".
    static func count(_ n: Int, _ singular: String, _ plural: String? = nil) -> String {
        "\(n) " + (n == 1 ? singular : (plural ?? singular + "s"))
    }

    /// The text trimmed, or nil when nothing is left.
    static func nonEmpty(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    /// "[00:12:31] Prof. Rahman: text" — a transcript line for the clipboard.
    static func transcriptLine(time: Double, speaker: String, text: String) -> String {
        "[\(KanTime.hms(time))] \(speaker): \(text)"
    }
}
