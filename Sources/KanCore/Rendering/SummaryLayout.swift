import Foundation

/// A call's OpenAI summary (`CallRecord.ai.summary`) as the Markdown and the plain text show it:
/// the overview, the lists that have items, and a note on who wrote it and when, whether the call
/// was too long to send whole, and whether the transcript changed since.
struct SummaryLayout {
    struct List {
        let heading: String
        /// Single-line NFC items; empty ones are left out.
        let items: [String]
    }

    /// The overview's paragraphs, each on one line.
    let overview: [String]
    /// Key points, ideas, decisions, action items, open questions: only the lists with items.
    let lists: [List]
    /// "Summary written by OpenAI (gpt-6.1-terra) on 17 Nov 2026; it can contain mistakes.", then
    /// the notes about a shortened or outdated summary.
    let notes: [String]

    /// nil when the call has no summary, or one without any text.
    init?(_ record: CallRecord) {
        guard let summary = record.ai?.summary, summary.hasText else { return nil }
        overview = SummaryLayout.paragraphs(summary.overview)
        let lists: [(String, [String])] = [("Key points", summary.keyPoints), ("Ideas", summary.ideas),
                                           ("Decisions", summary.decisions), ("Action items", summary.actionItems),
                                           ("Open questions", summary.openQuestions)]
        self.lists = lists.map { heading, items in
            List(heading: heading, items: items.map { $0.nfc.singleLine }.filter { !$0.isEmpty })
        }.filter { !$0.items.isEmpty }

        var written = "Summary written by OpenAI"
        if let model = summary.model.nonEmptyTrimmed?.singleLine { written += " (\(model))" }
        // `distantPast` is what a record without a readable date decodes to.
        if summary.generatedAt > .distantPast {
            written += " on " + TranscriptLayout.day(summary.generatedAt, timeZone: record.timeZone)
        }
        var notes = [written + "; it can contain mistakes."]
        if summary.shortened {
            notes.append("The call was too long to send whole, so the middle of the transcript was left out.")
        }
        if record.isSummaryOutdated { notes.append("The transcript changed after this summary was written.") }
        self.notes = notes
    }

    /// The paragraphs of `text` (separated by blank lines), each collapsed to one NFC line.
    static func paragraphs(_ text: String) -> [String] {
        var paragraphs: [String] = []
        var lines: [Substring] = []
        func flush() {
            let paragraph = lines.joined(separator: " ").nfc.singleLine
            if !paragraph.isEmpty { paragraphs.append(paragraph) }
            lines = []
        }
        // `isNewline`: "\r\n" is one Character, so splitting on "\n" alone would miss it.
        for line in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            if line.allSatisfy(\.isWhitespace) { flush() } else { lines.append(line) }
        }
        flush()
        return paragraphs
    }
}
