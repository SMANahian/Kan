import Foundation

// CONTRACT (implemented by the KanCore agent — keep these signatures; additions are fine).

public enum ExportFormat: String, CaseIterable, Codable, Sendable {
    case markdown, text, json, srt, vtt

    public var fileExtension: String {
        switch self {
        case .markdown: return "md"
        case .text: return "txt"
        case .json: return "json"
        case .srt: return "srt"
        case .vtt: return "vtt"
        }
    }

    public var displayName: String {
        switch self {
        case .markdown: return "Markdown"
        case .text: return "Plain text"
        case .json: return "JSON"
        case .srt: return "SubRip subtitles (.srt)"
        case .vtt: return "WebVTT subtitles (.vtt)"
        }
    }
}

public struct RenderOptions: Sendable, Equatable {
    public var includeFrontMatter: Bool
    public var includeNotes: Bool
    public var includeBookmarks: Bool
    /// Merge consecutive segments of the same speaker into one paragraph (gap < 2 s, < ~90 s total).
    public var mergeConsecutive: Bool
    /// Omit segments flagged `.echoSuspect`.
    public var hideEchoSuspects: Bool

    public init(includeFrontMatter: Bool = true, includeNotes: Bool = true, includeBookmarks: Bool = true,
                mergeConsecutive: Bool = true, hideEchoSuspects: Bool = true) {
        self.includeFrontMatter = includeFrontMatter
        self.includeNotes = includeNotes
        self.includeBookmarks = includeBookmarks
        self.mergeConsecutive = mergeConsecutive
        self.hideEchoSuspects = hideEchoSuspects
    }
}

/// Renders calls for humans and AI agents.
///
/// Markdown shape (front matter keys are stable — agents rely on them):
///
///     ---
///     kan_id: 01JD…
///     title: "Advisor meeting – augmentation idea"
///     date: 2026-11-14T10:00:12-05:00
///     end: 2026-11-14T10:42:25-05:00
///     duration: "00:42:13"
///     app: Zoom
///     platform: zoom
///     folder: "Research/Thesis"
///     tags: [research, thesis]
///     people: ["Nahian", "Prof. Rahman"]
///     languages: [en, bn]
///     starred: true
///     status: ready
///     ---
///
///     # Advisor meeting – augmentation idea
///     Fri 14 Nov 2026, 10:00–10:42 · Zoom · 42 min · Nahian (me), Prof. Rahman
///
///     ## Notes            (only if non-empty)
///     ## Bookmarks        (only if any)  - [00:12:31] note
///     ## Transcript
///     **Nahian** [00:00:05]
///     So I was thinking…
///
///     **Prof. Rahman** [00:00:21]
///     That's interesting…
///
/// Calls that are still processing render a "_Transcript is being generated…_" placeholder.
///
/// Details: `date`/`end` carry the call's own UTC offset; `folder` is "" for the Inbox; `people` is
/// the user first, then the other named people (placeholders like "Speaker 2" are left out). Extra
/// keys appear only when known: `me`, `attendees`, `calendar_event`, `meeting_url`. Recording,
/// queued and processing calls without a transcript show a placeholder; failed calls show the
/// error. A call being re-transcribed keeps showing its previous transcript (with a note).
///
/// All functions are pure and thread-safe.
public enum TranscriptRenderer {
    public static func markdown(_ record: CallRecord, options: RenderOptions = RenderOptions()) -> String {
        var out = ""
        if options.includeFrontMatter {
            out += frontMatter(record) + "\n"
        }
        let title = record.title.singleLine
        out += "# " + TranscriptLayout.escapeParagraphStart(title.isEmpty ? suggestedTitle(for: record) : title) + "\n"
        out += TranscriptLayout.headerLine(record) + "\n"

        let notes = record.notes.nfc.trimmingCharacters(in: .whitespacesAndNewlines)
        if options.includeNotes && !notes.isEmpty {
            out += "\n## Notes\n" + notes + "\n"
        }
        if options.includeBookmarks && !record.bookmarks.isEmpty {
            out += "\n## Bookmarks\n"
            for bookmark in record.bookmarks.sorted(by: { $0.time < $1.time }) {
                let note = bookmark.note.nfc.singleLine
                out += "- [\(bookmarkTime(bookmark))]" + (note.isEmpty ? "" : " " + TranscriptLayout.escapeInline(note)) + "\n"
            }
        }

        out += "\n## Transcript\n"
        let blocks = TranscriptLayout.blocks(record, options: options)
        if let note = TranscriptLayout.statusNote(record, hasTranscript: !blocks.isEmpty) {
            out += "_" + TranscriptLayout.escapeInline(note) + "_\n"
            if !blocks.isEmpty { out += "\n" }
        }
        out += blocks.map { block in
            let name = TranscriptLayout.escapeInline(record.speakerName(block.speakerID).singleLine)
            return "**\(name)** [\(KanTime.hms(block.start))]\n" + TranscriptLayout.escapeParagraphStart(block.text) + "\n"
        }.joined(separator: "\n")
        return out
    }

    /// "[00:00:05] Nahian: So I was thinking…" lines with a short header.
    ///
    /// `includeFrontMatter` controls the header (title + date line); with it, notes and bookmarks
    /// turned off, the result is just the transcript lines (what `{{transcript}}` uses).
    public static func plainText(_ record: CallRecord, options: RenderOptions = RenderOptions()) -> String {
        var sections: [String] = []
        if options.includeFrontMatter {
            sections.append(record.title.singleLine + "\n" + TranscriptLayout.headerLine(record))
        }
        let notes = record.notes.nfc.trimmingCharacters(in: .whitespacesAndNewlines)
        if options.includeNotes && !notes.isEmpty {
            sections.append("Notes:\n" + notes)
        }
        if options.includeBookmarks && !record.bookmarks.isEmpty {
            let lines = record.bookmarks.sorted(by: { $0.time < $1.time }).map { b -> String in
                let note = b.note.nfc.singleLine
                return "[\(bookmarkTime(b))]" + (note.isEmpty ? "" : " " + note)
            }
            sections.append("Bookmarks:\n" + lines.joined(separator: "\n"))
        }
        let transcript = transcriptLines(record, options: options)
        sections.append(sections.isEmpty ? transcript : "Transcript:\n" + transcript)
        return sections.joined(separator: "\n\n") + "\n"
    }

    /// The full CallRecord as pretty JSON (JSONEncoder.kanPretty).
    public static func json(_ record: CallRecord) throws -> Data {
        try JSONEncoder.kanPretty.encode(record)
    }

    /// SubRip: one cue per visible segment (echo suspects hidden), "Name: text".
    public static func srt(_ record: CallRecord) -> String {
        var blocks: [String] = []
        for cue in cues(record) {
            blocks.append("\(blocks.count + 1)\n\(KanTime.srt(cue.start)) --> \(KanTime.srt(cue.end))\n\(cue.speaker): \(cue.text)")
        }
        return blocks.isEmpty ? "" : blocks.joined(separator: "\n\n") + "\n"
    }

    /// WebVTT: one cue per visible segment (echo suspects hidden), "Name: text".
    public static func vtt(_ record: CallRecord) -> String {
        var out = "WEBVTT\n"
        for cue in cues(record) {
            out += "\n\(KanTime.vtt(cue.start)) --> \(KanTime.vtt(cue.end))\n"
            out += escapeVTT("\(cue.speaker): \(cue.text)") + "\n"
        }
        return out
    }

    public static func render(_ record: CallRecord, format: ExportFormat,
                              options: RenderOptions = RenderOptions()) throws -> Data {
        switch format {
        case .markdown: return Data(markdown(record, options: options).utf8)
        case .text: return Data(plainText(record, options: options).utf8)
        case .json: return try json(record)
        case .srt: return Data(srt(record).utf8)
        case .vtt: return Data(vtt(record).utf8)
        }
    }

    /// Fills a PromptTemplate's placeholders ({{title}}, {{date}}, {{me}}, {{participants}},
    /// {{transcript}} (plain text with timestamps), {{notes}}, {{duration}}).
    ///
    /// Also understood: {{bookmarks}}, {{tags}}, {{app}}. `{{notes}}` / `{{bookmarks}}` become a
    /// labeled block or nothing. Unknown placeholders are left as they are. The user's speaker is
    /// called `userName` when it still has the automatic name "Me".
    public static func aiPrompt(_ record: CallRecord, template: PromptTemplate, userName: String) -> String {
        var record = record
        let me = userName.nonEmptyTrimmed?.singleLine ?? record.me?.name.nonEmptyTrimmed?.singleLine ?? "Me"
        for i in record.speakers.indices where record.speakers[i].isMe && record.speakers[i].nameSource == .automatic {
            let name = record.speakers[i].name.trimmingCharacters(in: .whitespaces)
            if name.isEmpty || name.caseInsensitiveCompare("Me") == .orderedSame { record.speakers[i].name = me }
        }
        let notes = record.notes.nfc.trimmingCharacters(in: .whitespacesAndNewlines)
        let bookmarks = record.bookmarks.sorted(by: { $0.time < $1.time }).map { b -> String in
            let note = b.note.nfc.singleLine
            return "[\(bookmarkTime(b))]" + (note.isEmpty ? "" : " " + note)
        }
        let participants = TranscriptLayout.participants(record)
        let values: [String: String] = [
            "title": record.title.singleLine,
            "date": TranscriptLayout.dateRange(record),
            "me": me,
            "participants": participants.isEmpty ? "\(me) (me)" : participants,
            "transcript": transcriptLines(record, options: RenderOptions()),
            "notes": notes.isEmpty ? "" : "My notes:\n" + notes,
            "duration": KanTime.humanDuration(record.duration),
            "bookmarks": bookmarks.isEmpty ? "" : "Bookmarks:\n" + bookmarks.joined(separator: "\n"),
            "tags": record.tags.joined(separator: ", "),
            "app": TranscriptLayout.appLabel(record.source),
        ]
        let filled = fillPlaceholders(template.body, values)
        return collapseBlankLines(filled).trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    /// Suggested default title: calendar title > meeting title > "<App> call with <names>" > "<App> call".
    /// At most three names are listed ("Zoom call with Rahim, Karim, Ali and 2 others").
    public static func suggestedTitle(for record: CallRecord) -> String {
        if let title = record.calendarEventTitle?.nonEmptyTrimmed { return title.singleLine }
        if let title = record.source.meetingTitle?.nonEmptyTrimmed { return title.singleLine }
        let label = callLabel(record.source)
        let names = record.otherPeople
        guard !names.isEmpty else { return label }
        let shown = Array(names.prefix(3))
        let list: String
        switch (shown.count, names.count - shown.count) {
        case (1, _): list = shown[0]
        case (2, 0): list = "\(shown[0]) and \(shown[1])"
        case (_, 0): list = shown.dropLast().joined(separator: ", ") + " and " + (shown.last ?? "")
        case (_, let more): list = shown.joined(separator: ", ") + " and \(more) other\(more == 1 ? "" : "s")"
        }
        return "\(label) with \(list)"
    }

    /// The header line used in the Markdown and plain text:
    /// "Fri 14 Nov 2026, 10:00–10:42 · Zoom · 42 min · Nahian (me), Prof. Rahman".
    public static func summaryLine(_ record: CallRecord) -> String {
        TranscriptLayout.headerLine(record)
    }

    /// A file name for exporting the call: "<yyyy-MM-dd HHmm> <title>.<ext>".
    public static func suggestedFileName(for record: CallRecord, format: ExportFormat) -> String {
        LibraryNaming.baseName(for: record) + "." + format.fileExtension
    }

    // MARK: - Internals

    static func frontMatter(_ record: CallRecord) -> String {
        var lines = ["---"]
        func add(_ key: String, _ value: String) { lines.append("\(key): \(value)") }
        // A ULID is plain-safe once it contains a letter (an all-digit one would read as a number).
        let id = record.id.rawValue
        let plainID = id.contains(where: \.isLetter) && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
        add("kan_id", plainID ? id : YAML.quoted(id))
        add("title", YAML.quoted(record.title.singleLine))
        add("date", TranscriptLayout.isoDate(record.startedAt, timeZone: record.timeZone))
        add("end", TranscriptLayout.isoDate(record.endedAt, timeZone: record.timeZone))
        add("duration", YAML.quoted(KanTime.hms(record.duration)))
        add("app", YAML.scalar(record.source.appName.singleLine))
        add("platform", YAML.scalar(record.source.platform.rawValue))
        add("folder", YAML.quoted(record.folder))
        add("tags", YAML.flowList(record.tags.map(\.singleLine)))
        add("people", YAML.flowList(TranscriptLayout.people(record), alwaysQuote: true))
        add("languages", YAML.flowList(record.languages))
        add("starred", record.starred ? "true" : "false")
        add("status", record.status.rawValue)
        if let me = record.me?.name.nonEmptyTrimmed { add("me", YAML.quoted(me.singleLine)) }
        if !record.attendees.isEmpty { add("attendees", YAML.flowList(record.attendees.map(\.singleLine), alwaysQuote: true)) }
        if let event = record.calendarEventTitle?.nonEmptyTrimmed { add("calendar_event", YAML.quoted(event.singleLine)) }
        if let url = record.source.meetingURL?.nonEmptyTrimmed { add("meeting_url", YAML.quoted(url.singleLine)) }
        lines.append("---")
        return lines.joined(separator: "\n") + "\n"
    }

    /// "[00:00:05] Nahian: …" lines (merged per options), or a parenthesized status note.
    static func transcriptLines(_ record: CallRecord, options: RenderOptions) -> String {
        let blocks = TranscriptLayout.blocks(record, options: options)
        var lines: [String] = []
        if let note = TranscriptLayout.statusNote(record, hasTranscript: !blocks.isEmpty) {
            lines.append("(\(note))")
        }
        for block in blocks {
            lines.append("[\(KanTime.hms(block.start))] \(record.speakerName(block.speakerID).singleLine): \(block.text)")
        }
        return lines.joined(separator: "\n")
    }

    private struct Cue {
        var start: Double
        var end: Double
        var speaker: String
        var text: String
    }

    private static func cues(_ record: CallRecord) -> [Cue] {
        record.visibleSegments(hidingEchoSuspects: true).compactMap { segment in
            let text = segment.text.nfc.singleLine
            guard !text.isEmpty else { return nil }
            let start = max(0, segment.start)
            // Players skip empty or inverted cues; give those a short duration.
            let end = segment.end > start ? segment.end : start + 0.5
            return Cue(start: start, end: end, speaker: record.speakerName(segment.speakerID).singleLine, text: text)
        }
    }

    private static func escapeVTT(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func bookmarkTime(_ bookmark: Bookmark) -> String {
        if let end = bookmark.endTime, end > bookmark.time {
            return "\(KanTime.hms(bookmark.time))–\(KanTime.hms(end))"
        }
        return KanTime.hms(bookmark.time)
    }

    private static func callLabel(_ source: CallSource) -> String {
        switch source.platform {
        case .manual: return "Recording"
        case .imported: return "Imported audio"
        case .browser, .other:
            return (source.appName.nonEmptyTrimmed?.singleLine).map { "\($0) call" } ?? "Call"
        default:
            return "\(source.platform.displayName) call"
        }
    }

    /// Replaces "{{key}}" (spaces inside the braces allowed, key case-insensitive).
    private static func fillPlaceholders(_ template: String, _ values: [String: String]) -> String {
        var out = ""
        var rest = Substring(template)
        while let open = rest.range(of: "{{") {
            out += rest[..<open.lowerBound]
            let afterOpen = rest[open.upperBound...]
            guard let close = afterOpen.range(of: "}}") else {
                out += rest[open.lowerBound...]
                return out
            }
            let key = afterOpen[..<close.lowerBound].trimmingCharacters(in: .whitespaces).lowercased()
            if let value = values[key], !key.contains("{") {
                out += value
                rest = afterOpen[close.upperBound...]
            } else {
                out += "{{"
                rest = afterOpen
            }
        }
        out += rest
        return out
    }

    /// At most one empty line in a row (left behind by empty placeholders).
    private static func collapseBlankLines(_ text: String) -> String {
        var out: [Substring] = []
        var blank = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                blank += 1
                if blank > 1 { continue }
            } else {
                blank = 0
            }
            out.append(line)
        }
        return out.joined(separator: "\n")
    }
}
