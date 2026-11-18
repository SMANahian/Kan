import Foundation

extension Speaker {
    /// The name the transcriber gives a remote speaker nobody has named yet ("Speaker 1").
    public static func defaultName(number: Int) -> String { "Speaker \(number)" }

    /// True for placeholder names: "Speaker", "Speaker 3", an empty name.
    public static func isDefaultName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        let prefix = "speaker"
        guard trimmed.lowercased().hasPrefix(prefix) else { return false }
        let rest = trimmed.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
        return rest.isEmpty || rest.allSatisfy(\.isNumber)
    }

    /// True while the speaker still has a placeholder name.
    public var hasDefaultName: Bool { Speaker.isDefaultName(name) }
}

extension CallRecord {
    /// Display name for a speaker id ("Unknown speaker" when the id isn't in `speakers`).
    public func speakerName(_ id: String) -> String {
        if let speaker = speaker(id), let name = speaker.name.nonEmptyTrimmed { return name }
        return id == Speaker.meID ? "Me" : "Unknown speaker"
    }

    /// Names of the other people on the call: named remote speakers (no placeholders, not the user),
    /// in speaker order, without duplicates.
    public var otherPeople: [String] {
        speakers
            .filter { !$0.isMe && $0.id != Speaker.meID && !$0.hasDefaultName }
            .compactMap { $0.name.nonEmptyTrimmed }
            .filter { $0.caseInsensitiveCompare("Me") != .orderedSame }
            .uniquedCaseInsensitive()
    }

    /// True when the summary was written from another version of the transcript: an earlier
    /// transcription, or before a speaker was renamed or a line edited (`CallInsights.fingerprint`).
    public var isSummaryOutdated: Bool {
        guard let summary = ai?.summary else { return false }
        return summary.fingerprint != CallInsights.fingerprint(of: self)
    }

    /// True when the title ideas were written from another version of the transcript.
    public var areTitleIdeasOutdated: Bool {
        guard let ideas = ai?.titleSuggestions else { return false }
        return ideas.fingerprint != CallInsights.fingerprint(of: self)
    }

    /// Segments shown to readers: echo suspects (mic bleed of the remote side) removed when asked.
    func visibleSegments(hidingEchoSuspects: Bool) -> [TranscriptSegment] {
        let kept = hidingEchoSuspects ? segments.filter { !$0.flags.contains(.echoSuspect) } : segments
        // Stable order by start time (user edits may have appended segments out of order).
        return kept.enumerated().sorted { a, b in
            a.element.start != b.element.start ? a.element.start < b.element.start : a.offset < b.offset
        }.map(\.element)
    }
}

extension AISummary {
    /// The overview and every list item, in the order the Markdown shows them.
    var texts: [String] { [overview] + keyPoints + ideas + decisions + actionItems + openQuestions }

    /// There is something to show: an overview or a list item that isn't blank.
    public var hasText: Bool { texts.contains { !$0.singleLine.isEmpty } }
}

extension CallSummary {
    /// Builds the lightweight row for a record. Paths are relative to the library root.
    public init(record: CallRecord, markdownPath: String = "", jsonPath: String = "") {
        let visible = record.visibleSegments(hidingEchoSuspects: true)
        var words = 0
        for segment in visible { words += CallSummary.wordCount(segment.text) }
        self.init(id: record.id, title: record.title, folder: record.folder, tags: record.tags,
                  starred: record.starred, labeled: record.labeled, startedAt: record.startedAt,
                  endedAt: record.endedAt, timeZone: record.timeZone, appName: record.source.appName,
                  platform: record.source.platform, status: record.status,
                  speakerNames: record.speakers.map(\.name), languages: record.languages,
                  segmentCount: record.segments.count, wordCount: words,
                  hasAudio: record.audio?.isAvailable ?? false,
                  hasSummary: record.ai?.summary?.hasText ?? false,
                  preview: CallSummary.preview(for: record, visible: visible),
                  markdownPath: markdownPath, jsonPath: jsonPath)
    }

    static let previewLength = 160

    /// The user's notes, else the summary's overview, else the transcript.
    static func preview(for record: CallRecord, visible: [TranscriptSegment]) -> String {
        let notes = record.notes.singleLine
        if !notes.isEmpty { return notes.truncated(maxCharacters: previewLength) }
        if let overview = record.ai?.summary?.overview.nfc.singleLine, !overview.isEmpty {
            return overview.truncated(maxCharacters: previewLength)
        }
        var text = ""
        for segment in visible {
            let line = segment.text.singleLine
            guard !line.isEmpty else { continue }
            if !text.isEmpty { text += " " }
            text += line
            if text.count > previewLength { break }
        }
        return text.truncated(maxCharacters: previewLength)
    }

    /// Whitespace-separated words (Bangla is space-separated too).
    static func wordCount(_ text: String) -> Int {
        var count = 0
        var inWord = false
        for scalar in text.unicodeScalars {
            if scalar.isSpaceOrControl {
                inWord = false
            } else if !inWord {
                inWord = true
                count += 1
            }
        }
        return count
    }
}
