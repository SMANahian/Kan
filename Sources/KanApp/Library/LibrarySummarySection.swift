import SwiftUI
import KanAI
import KanCore

/// OpenAI's summary of the call, above the transcript: the overview and the lists that have items
/// (selectable; a timestamp like [00:12:34] plays from that moment), who wrote it and when, a note
/// when the transcript changed since or was too long to send whole, and Copy / Regenerate / Remove.
/// It folds away to one line. Without a summary it is a single strip — "Summarize with OpenAI"
/// while a key is saved, the job's progress or error — and nothing at all without a key.
struct LibrarySummarySection: View {
    let detail: LibraryCallDetailModel
    @Environment(AppModel.self) private var model
    @AppStorage(LibraryDefaults.summaryCollapsed) private var collapsed = false
    @State private var contentHeight: CGFloat = 0

    /// Above this the summary scrolls on its own, so the transcript keeps most of the window.
    static let maxContentHeight: CGFloat = 250

    var body: some View {
        if let record = detail.record {
            let job = model.aiJob(.summary, for: record.id)
            if let summary = record.ai?.summary, summary.hasText {
                VStack(spacing: 0) {
                    Divider()
                    written(record, summary, job: job)
                }
            } else if model.apiKeyState.isSaved || job != nil {
                VStack(spacing: 0) {
                    Divider()
                    unwritten(record, job: job)
                }
            }
        }
    }

    // MARK: No summary yet

    private func unwritten(_ record: CallRecord, job: AIJobState?) -> some View {
        HStack(spacing: 8) {
            Label("Summary", systemImage: "sparkles")
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
                .fixedSize()
            switch job {
            case .running?:
                ProgressView().controlSize(.small)
                Text("OpenAI is writing the summary…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button("Cancel") { detail.cancelSummary() }
                    .controlSize(.small)
            case .waiting?:
                Text("Written once you close the label panel")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help("So it uses the speaker names you give there")
                Spacer(minLength: 8)
                summarizeButton(record, title: "Summarize Now")
            case .failed(let error)?:
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(error.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
                Spacer(minLength: 8)
                if model.apiKeyState.isSaved { summarizeButton(record, title: "Retry") }
            case nil:
                Text("Key points, ideas, decisions and action items")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                summarizeButton(record, title: "Summarize with OpenAI")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 6)
    }

    private func summarizeButton(_ record: CallRecord, title: String) -> some View {
        let ready = AppModel.hasTranscriptForOpenAI(record)
        return Button(title) { detail.summarize() }
            .controlSize(.small)
            .disabled(!ready)
            .help(ready ? "Sends this call's transcript — never the audio — to OpenAI with your API key"
                        : "Available once the call has a transcript")
    }

    // MARK: The summary

    private func written(_ record: CallRecord, _ summary: AISummary, job: AIJobState?) -> some View {
        let outdated = detail.summaryOutdated
        let canWrite = canWriteAgain(record, job: job)
        return VStack(alignment: .leading, spacing: 0) {
            header(record, summary, job: job, outdated: outdated, canWrite: canWrite)
            if !collapsed {
                if job == .running {
                    notice("OpenAI is writing it again…", action: "Cancel", perform: detail.cancelSummary) {
                        ProgressView().controlSize(.mini)
                    }
                } else if case .failed(let error)? = job {
                    notice("Couldn't write it again: \(error.message)", action: canWrite ? "Retry" : nil, perform: detail.summarize) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                } else if outdated {
                    notice("The transcript changed after this summary was written.", action: canWrite ? "Regenerate" : nil,
                           perform: detail.summarize) {
                        Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                    }
                }
                let clipped = contentHeight > Self.maxContentHeight
                ScrollView {
                    content(record, summary)
                        .background(GeometryReader { proxy in
                            Color.clear.preference(key: LibrarySummaryHeightKey.self, value: proxy.size.height)
                        })
                }
                .frame(height: min(max(contentHeight, 1), Self.maxContentHeight))
                // Fades out where a long summary goes on below (it scrolls).
                .mask {
                    VStack(spacing: 0) {
                        Color.black
                        LinearGradient(colors: [.black, .black.opacity(clipped ? 0 : 1)], startPoint: .top, endPoint: .bottom)
                            .frame(height: 16)
                    }
                }
                .onPreferenceChange(LibrarySummaryHeightKey.self) { contentHeight = $0 }
            }
        }
        .background(Color.accentColor.opacity(0.04))
    }

    /// A key is saved, nothing is running and the transcript is ready.
    private func canWriteAgain(_ record: CallRecord, job: AIJobState?) -> Bool {
        model.apiKeyState.isSaved && job != .running && AppModel.hasTranscriptForOpenAI(record)
    }

    private func header(_ record: CallRecord, _ summary: AISummary, job: AIJobState?, outdated: Bool,
                        canWrite: Bool) -> some View {
        HStack(spacing: 8) {
            Button {
                withAnimation(.snappy(duration: 0.2)) { collapsed.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(collapsed ? 0 : 90))
                    Label("Summary", systemImage: "sparkles")
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                }
                .fixedSize()
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(collapsed ? "Show the summary" : "Hide the summary")
            if collapsed {
                // A glimpse of it while folded away.
                Text(LibrarySummaryText.paragraphs(summary.overview).first ?? "")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if outdated {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(.orange)
                        .help("The transcript changed after this summary was written")
                }
            }
            Spacer(minLength: 8)
            if job == .running && collapsed {
                ProgressView()
                    .controlSize(.small)
                    .help("OpenAI is writing it again…")
            }
            Button {
                detail.copySummary()
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("Copy the summary")
            Button {
                detail.summarize()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .disabled(!canWrite)
            .help(model.apiKeyState.isSaved ? "Write it again with OpenAI" : "Add an OpenAI API key in Settings to write it again")
            Menu {
                Button("Copy Summary") { detail.copySummary() }
                Button("Regenerate") { detail.summarize() }
                    .disabled(!canWrite)
                Divider()
                Button("Remove Summary…", role: .destructive) { detail.requestRemoveSummary() }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 6)
    }

    /// A note above the summary (writing it again, failed, outdated), with its button.
    private func notice<Leading: View>(_ text: String, action: String?, perform: @escaping () -> Void,
                                       @ViewBuilder leading: () -> Leading) -> some View {
        HStack(spacing: 6) {
            leading()
            Text(text)
                .lineLimit(2)
            Spacer(minLength: 8)
            if let action {
                Button(action, action: perform)
                    .controlSize(.small)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 20)
        .padding(.bottom, 6)
    }

    private func content(_ record: CallRecord, _ summary: AISummary) -> some View {
        let terms = LibraryTextMatch.terms(in: detail.findQuery)
        return VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(LibrarySummaryText.paragraphs(summary.overview).enumerated()), id: \.offset) { _, paragraph in
                Text(LibrarySummaryText.attributed(paragraph, terms: terms))
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(LibrarySummaryText.lists(summary)) { list in
                VStack(alignment: .leading, spacing: 4) {
                    Label(list.heading, systemImage: list.symbol)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(Array(list.items.enumerated()), id: \.offset) { _, item in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("•")
                                .foregroundStyle(.secondary)
                            Text(LibrarySummaryText.attributed(item, terms: terms))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.leading, 4)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                if summary.shortened {
                    Text("The call was too long to send whole, so the middle of the transcript was left out.")
                }
                Text(LibrarySummaryText.byline(summary))
            }
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
        .font(.callout)
        .lineSpacing(2)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.top, 2)
        .padding(.bottom, 12)
        // The summary's timestamps are links to that moment of the call.
        .environment(\.openURL, OpenURLAction { url in
            guard let seconds = LibrarySummaryText.seconds(fromLink: url) else { return .systemAction }
            detail.go(to: seconds)
            return .handled
        })
    }
}

private struct LibrarySummaryHeightKey: PreferenceKey {
    static var defaultValue: CGFloat { 0 }

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// The summary as the library window shows and copies it: paragraphs, the lists with items, the
/// byline, and timestamps as links. Pure.
enum LibrarySummaryText {
    struct List: Identifiable, Equatable {
        let heading: String
        let symbol: String
        /// Single-line; blank ones left out.
        let items: [String]
        var id: String { heading }
    }

    /// The overview's paragraphs (separated by blank lines), each on one line.
    static func paragraphs(_ text: String) -> [String] {
        var paragraphs: [String] = []
        var lines: [Substring] = []
        func flush() {
            let paragraph = LibraryTextMatch.singleLine(lines.joined(separator: " "))
            if !paragraph.isEmpty { paragraphs.append(paragraph) }
            lines = []
        }
        for line in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            if line.allSatisfy(\.isWhitespace) { flush() } else { lines.append(line) }
        }
        flush()
        return paragraphs
    }

    /// Key points, ideas, decisions, action items, open questions: those with items.
    static func lists(_ summary: AISummary) -> [List] {
        [List(heading: "Key points", symbol: "list.bullet", items: summary.keyPoints),
         List(heading: "Ideas", symbol: "lightbulb", items: summary.ideas),
         List(heading: "Decisions", symbol: "checkmark.seal", items: summary.decisions),
         List(heading: "Action items", symbol: "checklist", items: summary.actionItems),
         List(heading: "Open questions", symbol: "questionmark.bubble", items: summary.openQuestions)]
            .map { List(heading: $0.heading, symbol: $0.symbol, items: $0.items.map(LibraryTextMatch.singleLine).filter { !$0.isEmpty }) }
            .filter { !$0.items.isEmpty }
    }

    /// "Written by OpenAI (GPT-6.1 Terra) on 17 Nov 2026 at 14:31 · It can contain mistakes: check
    /// the transcript for what was said."
    static func byline(_ summary: AISummary) -> String {
        var text = "Written by OpenAI"
        let model = summary.model.trimmingCharacters(in: .whitespacesAndNewlines)
        if !model.isEmpty { text += " (\(OpenAIModels.option(for: model)?.name ?? model))" }
        // `distantPast` is what a summary without a readable date decodes to.
        if summary.generatedAt > .distantPast {
            text += " on " + summary.generatedAt.formatted(date: .abbreviated, time: .shortened)
        }
        return text + " · It can contain mistakes: check the transcript for what was said."
    }

    /// The summary for the clipboard: plain text that reads well anywhere (and as Markdown).
    static func clipboardText(_ record: CallRecord) -> String? {
        guard let summary = record.ai?.summary, summary.hasText else { return nil }
        var blocks = ["Summary of “\(LibraryTextMatch.singleLine(record.title))”"]
        blocks += paragraphs(summary.overview)
        for list in lists(summary) {
            blocks.append(list.heading + ":\n" + list.items.map { "- " + $0 }.joined(separator: "\n"))
        }
        if summary.shortened {
            blocks.append("(The call was too long to send whole; the middle of the transcript was left out.)")
        }
        blocks.append(byline(summary))
        return blocks.joined(separator: "\n\n") + "\n"
    }

    /// The timestamps `text` cites — "[00:12:34]", "[12:34]", "[00:12:34–00:13:10]" — with the
    /// second each starts at.
    static func timestamps(in text: String) -> [(range: Range<String.Index>, seconds: Double)] {
        guard let timestampPattern else { return [] }
        let ns = text as NSString
        return timestampPattern.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { match in
            guard let range = Range(match.range, in: text) else { return nil }
            func number(_ group: Int) -> Int? {
                let r = match.range(at: group)
                return r.location == NSNotFound ? nil : Int(ns.substring(with: r))
            }
            guard let first = number(1), let second = number(2) else { return nil }
            let seconds: Int
            if let third = number(3) {
                guard second < 60, third < 60 else { return nil }
                seconds = first * 3600 + second * 60 + third
            } else {
                guard second < 60 else { return nil }
                seconds = first * 60 + second
            }
            return (range, Double(seconds))
        }
    }

    /// "[h:mm:ss" or "[mm:ss", optionally "–" and a second time, then "]".
    private static let timestampPattern =
        try? NSRegularExpression(pattern: #"\[(\d{1,2}):(\d{2})(?::(\d{2}))?(?:\s*[–—-]\s*\d{1,2}:\d{2}(?::\d{2})?)?\]"#)

    /// `text` with the find terms highlighted and its timestamps as links (`link(seconds:)`).
    static func attributed(_ text: String, terms: [String]) -> AttributedString {
        var out = AttributedString()
        var cursor = text.startIndex
        for stamp in timestamps(in: text) {
            if cursor < stamp.range.lowerBound {
                out += LibraryHighlightedText.attributed(String(text[cursor..<stamp.range.lowerBound]), terms: terms)
            }
            var link = AttributedString(String(text[stamp.range]))
            link.link = self.link(seconds: stamp.seconds)
            out += link
            cursor = stamp.range.upperBound
        }
        if cursor < text.endIndex { out += LibraryHighlightedText.attributed(String(text[cursor...]), terms: terms) }
        return out
    }

    static func link(seconds: Double) -> URL? {
        URL(string: "kan-time:\(Int(seconds))")
    }

    static func seconds(fromLink url: URL) -> Double? {
        guard url.scheme == "kan-time" else { return nil }
        return Double(url.absoluteString.dropFirst("kan-time:".count))
    }
}
