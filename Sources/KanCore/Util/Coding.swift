import Foundation

extension JSONEncoder {
    /// Pretty, stable output with ISO-8601 dates (what Kan writes to disk).
    public static var kanPretty: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(KanDate.iso8601(date))
        }
        return e
    }

    /// Single-line output (index.jsonl, MCP responses).
    public static var kanCompact: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(KanDate.iso8601(date))
        }
        return e
    }
}

extension JSONDecoder {
    /// Accepts ISO-8601 dates with or without fractional seconds.
    public static var kan: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            if let s = try? c.decode(String.self), let date = KanDate.parse(s) { return date }
            if let t = try? c.decode(Double.self) { return Date(timeIntervalSince1970: t) }
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unrecognized date")
        }
        return d
    }
}

public enum KanDate {
    /// ISO-8601 in the local time zone with offset, e.g. 2026-11-16T15:30:12.345-05:00.
    public static func iso8601(_ date: Date, timeZone: TimeZone = .current) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = timeZone
        return f.string(from: date)
    }

    public static func parse(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}

public enum KanTime {
    /// 3725.4 → "01:02:05"; always hours.
    public static func hms(_ seconds: Double) -> String {
        let s = Int(max(0, seconds).rounded(.down))
        return String(format: "%02d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }

    /// 125.4 → "2:05"; 3725 → "1:02:05".
    public static func compact(_ seconds: Double) -> String {
        let s = Int(max(0, seconds).rounded(.down))
        if s >= 3600 { return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) }
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    /// 2532 → "42 min"; 45 → "45 s"; 5400 → "1 h 30 min".
    public static func humanDuration(_ seconds: Double) -> String {
        let s = Int(max(0, seconds).rounded())
        if s < 60 { return "\(s) s" }
        let m = s / 60
        if m < 60 { return "\(m) min" }
        let h = m / 60, rem = m % 60
        return rem == 0 ? "\(h) h" : "\(h) h \(rem) min"
    }

    /// SRT timestamp "00:01:02,345".
    public static func srt(_ seconds: Double) -> String {
        let ms = Int((max(0, seconds) * 1000).rounded())
        return String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, (ms % 3_600_000) / 60_000, (ms % 60_000) / 1000, ms % 1000)
    }

    /// WebVTT timestamp "00:01:02.345".
    public static func vtt(_ seconds: Double) -> String {
        srt(seconds).replacingOccurrences(of: ",", with: ".")
    }
}

extension String {
    /// Unicode NFC. Bangla nukta letters (য় ড় ঢ়) have precomposed and decomposed forms that
    /// compare equal in Swift but differ in bytes — always store and index NFC.
    public var nfc: String { precomposedStringWithCanonicalMapping }
}
