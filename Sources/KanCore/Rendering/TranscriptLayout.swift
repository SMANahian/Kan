import Foundation

/// Shared pieces of the Markdown / plain-text layouts.
enum TranscriptLayout {
    /// Consecutive same-speaker segments closer than this are one paragraph…
    static let mergeGap: Double = 2
    /// …as long as the paragraph stays shorter than this.
    static let maxParagraphSeconds: Double = 90

    struct Block {
        var speakerID: String
        var start: Double
        var end: Double
        var texts: [String]

        var text: String { texts.joined(separator: " ") }
    }

    /// Speaker turns: visible segments, merged per `RenderOptions.mergeConsecutive`.
    static func blocks(_ record: CallRecord, options: RenderOptions) -> [Block] {
        var blocks: [Block] = []
        for segment in record.visibleSegments(hidingEchoSuspects: options.hideEchoSuspects) {
            let text = segment.text.nfc.singleLine
            guard !text.isEmpty else { continue }
            if options.mergeConsecutive, var last = blocks.last, last.speakerID == segment.speakerID,
               segment.start - last.end < mergeGap, segment.end - last.start <= maxParagraphSeconds {
                last.end = max(last.end, segment.end)
                last.texts.append(text)
                blocks[blocks.count - 1] = last
            } else {
                blocks.append(Block(speakerID: segment.speakerID, start: segment.start, end: segment.end, texts: [text]))
            }
        }
        return blocks
    }

    // MARK: Dates

    private static func formatter(_ format: String, _ timeZone: TimeZone) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = timeZone
        f.dateFormat = format
        return f
    }

    /// "Fri 14 Nov 2026, 10:00–10:42" in the call's time zone (the end gets a date when it differs).
    static func dateRange(_ record: CallRecord) -> String {
        let zone = LibraryNaming.timeZone(record.timeZone)
        let start = formatter("EEE d MMM yyyy, HH:mm", zone).string(from: record.startedAt)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let sameDay = calendar.isDate(record.startedAt, inSameDayAs: record.endedAt)
        let end = formatter(sameDay ? "HH:mm" : "EEE d MMM yyyy, HH:mm", zone).string(from: record.endedAt)
        return "\(start)–\(end)"
    }

    /// ISO-8601 with the call's own UTC offset, no fractional seconds: 2026-11-14T10:00:12-05:00.
    static func isoDate(_ date: Date, timeZone identifier: String) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = LibraryNaming.timeZone(identifier)
        return f.string(from: date)
    }

    // MARK: Labels

    /// "Zoom", or "Google Meet (Zen)" for a meeting platform used through another app.
    static func appLabel(_ source: CallSource) -> String {
        let app = source.appName.nonEmptyTrimmed ?? source.platform.displayName
        switch source.platform {
        case .browser, .manual, .imported, .other:
            return app
        default:
            let platform = source.platform.displayName
            if platform.caseInsensitiveCompare(app) == .orderedSame || app.localizedCaseInsensitiveContains(platform) {
                return app
            }
            return "\(platform) (\(app))"
        }
    }

    /// "Nahian (me), Prof. Rahman, Speaker 2"; falls back to attendees before transcription.
    static func participants(_ record: CallRecord) -> String {
        if !record.speakers.isEmpty {
            return record.speakers.map { $0.isMe ? "\(displayName($0)) (me)" : displayName($0) }.joined(separator: ", ")
        }
        return record.attendees.joined(separator: ", ")
    }

    static func displayName(_ speaker: Speaker) -> String {
        speaker.name.nonEmptyTrimmed?.singleLine ?? (speaker.isMe ? "Me" : "Unknown speaker")
    }

    /// "Fri 14 Nov 2026, 10:00–10:42 · Zoom · 42 min · Nahian (me), Prof. Rahman"
    static func headerLine(_ record: CallRecord) -> String {
        var parts = [dateRange(record), appLabel(record.source), KanTime.humanDuration(record.duration)]
        let people = participants(record)
        if !people.isEmpty { parts.append(people) }
        return parts.joined(separator: " · ")
    }

    /// Front-matter `people`: the user first, then the other named people.
    static func people(_ record: CallRecord) -> [String] {
        var names: [String] = []
        if let me = record.me?.name.nonEmptyTrimmed { names.append(me.singleLine) }
        names.append(contentsOf: record.otherPeople)
        return names.uniquedCaseInsensitive()
    }

    // MARK: Transcript states

    /// Placeholder shown instead of (or above) the transcript, without Markdown emphasis.
    static func statusNote(_ record: CallRecord, hasTranscript: Bool) -> String? {
        let error = record.processing?.error?.nonEmptyTrimmed?.singleLine
        switch record.status {
        case .recording:
            return hasTranscript ? nil : "Recording in progress — the transcript will appear after the call."
        case .queued, .processing:
            return hasTranscript ? "A new transcript is being generated; this is the previous one."
                                 : "Transcript is being generated…"
        case .failed:
            let reason = error ?? "unknown error"
            return hasTranscript ? "The last transcription attempt failed (\(reason)); this is the previous transcript."
                                 : "Transcription failed: \(reason). The audio was kept, so the call can be transcribed again."
        case .ready:
            return hasTranscript ? nil : "No speech was detected in this call."
        }
    }

    // MARK: Markdown escaping

    /// Escapes characters that would start emphasis, code or links inside inline text.
    static func escapeInline(_ text: String) -> String {
        var out = ""
        for character in text {
            if "\\*_`[]<".contains(character) { out.append("\\") }
            out.append(character)
        }
        return out
    }

    /// Keeps a paragraph from being read as a heading, list, quote, rule, table or code fence.
    static func escapeParagraphStart(_ text: String) -> String {
        guard let first = text.first else { return text }
        if "#>-+*=|~`".contains(first) { return "\\" + text }
        let digits = text.prefix { $0.isASCII && $0.isNumber }
        if !digits.isEmpty, digits.count <= 9 {
            let rest = text.dropFirst(digits.count)
            if let marker = rest.first, marker == "." || marker == ")",
               rest.dropFirst().first.map({ $0 == " " }) ?? true {
                return String(digits) + "\\" + rest
            }
        }
        return text
    }
}
