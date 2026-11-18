import Foundation
import KanCore

/// Turning command-line words into a search query. Pure.
public enum CLIQuery {
    private static let quoteMarks: Set<Character> = ["\"", "“", "”", "„", "‟", "«", "»"]

    /// The words as a query: a word containing spaces was quoted in the shell, so it stays a phrase.
    public static func text(_ words: [String]) -> String {
        words.map { word in
            let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.contains(where: \.isWhitespace) && !trimmed.contains(where: quoteMarks.contains) {
                return "\"" + trimmed + "\""
            }
            return trimmed
        }.filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// False when the query is only quotes and spaces (it would match every call).
    public static func hasTerms(_ text: String) -> Bool {
        text.contains { !$0.isWhitespace && !quoteMarks.contains($0) }
    }
}

/// Human-readable output of the CLI commands. Pure.
enum CLIText {
    static let maxTitleWidth = 60
    static let maxFolderWidth = 28

    // MARK: list

    static func callTable(_ page: CallPage, prefixLength: Int, libraryEmpty: Bool, root: URL) -> String {
        guard !page.calls.isEmpty else {
            if libraryEmpty { return "No calls yet in \(root.path).\n" }
            return page.total > 0 ? "No calls at offset \(page.offset) (there are \(page.total)).\n" : "No calls match.\n"
        }
        struct Row {
            var id, date, length, folder, title, tags: String
        }
        let rows = page.calls.map { s -> Row in
            var title = s.title.singleLineText
            if s.starred { title += " ★" }
            if s.status != .ready { title += " [\(s.status.rawValue)]" }
            return Row(id: String(s.id.rawValue.prefix(prefixLength)),
                       date: AgentFormat.shortDate(s.startedAt, timeZone: s.timeZone),
                       length: KanTime.humanDuration(s.duration),
                       folder: (s.folder.isEmpty ? "Inbox" : s.folder).truncated(toWidth: maxFolderWidth),
                       title: title.truncated(toWidth: maxTitleWidth),
                       tags: s.tags.map { "#" + $0.singleLineText }.joined(separator: " "))
        }
        let header = Row(id: "ID", date: "STARTED", length: "LENGTH", folder: "FOLDER", title: "TITLE", tags: "TAGS")
        let all = [header] + rows
        let idWidth = all.map(\.id.displayWidth).max() ?? 0
        let dateWidth = all.map(\.date.displayWidth).max() ?? 0
        let lengthWidth = all.map(\.length.displayWidth).max() ?? 0
        let folderWidth = all.map(\.folder.displayWidth).max() ?? 0
        let titleWidth = all.map(\.title.displayWidth).max() ?? 0
        let showTags = rows.contains { !$0.tags.isEmpty }
        var out = ""
        for (index, row) in all.enumerated() {
            var line = row.id.padded(toWidth: idWidth) + "  " + row.date.padded(toWidth: dateWidth) + "  "
            line += (index == 0 ? row.length.padded(toWidth: lengthWidth) : row.length.leftPadded(toWidth: lengthWidth)) + "  "
            line += row.folder.padded(toWidth: folderWidth) + "  "
            line += showTags ? row.title.padded(toWidth: titleWidth) + "  " + row.tags : row.title
            out += line.trimmingTrailingSpaces + "\n"
        }
        if let next = page.nextOffset {
            out += "\nShowing \(page.offset + 1)–\(page.offset + page.calls.count) of \(page.total) calls; "
                + "--offset \(next) shows the next page, --limit 0 all of them.\n"
        }
        return out
    }

    // MARK: search

    static func searchResults(_ results: PassageResults, query: String, prefixLength: Int) -> String {
        guard !results.passages.isEmpty else { return "No matches for \(query).\n" }
        var out = ""
        var current: CallID?
        for passage in results.passages {
            let s = passage.summary, hit = passage.hit
            if current != s.id {
                if current != nil { out += "\n" }
                current = s.id
                out += s.title.singleLineText + (s.starred ? " ★" : "") + "\n"
                out += "  " + [AgentFormat.shortDate(s.startedAt, timeZone: s.timeZone), s.appName,
                               s.folder.isEmpty ? "Inbox" : s.folder, "id " + String(s.id.rawValue.prefix(prefixLength))]
                    .joined(separator: " · ") + "\n"
            }
            switch hit.field {
            case .transcript:
                out += "  [\(KanTime.hms(hit.time ?? 0))] \(hit.speakerName ?? "Unknown speaker"): \(hit.snippet)\n"
            case .bookmark:
                out += "  bookmark [\(KanTime.hms(hit.time ?? 0))]: \(hit.snippet)\n"
            case .title, .tags, .notes, .summary:
                out += "  \(hit.field.rawValue): \(hit.snippet)\n"
            }
        }
        out += "\n" + AgentFormat.count(results.passages.count, "passage") + " in " + AgentFormat.count(results.matchedCalls, "call")
        if results.truncated {
            out += " (of \(results.totalHits) matches; --limit 0 --per-call 0 shows all)"
        }
        out += ". `kan show <id>` prints a whole call.\n"
        return out
    }

    // MARK: folders, tags, people

    static func folders(_ rows: [FolderRow]) -> String {
        let labels = rows.map { String(repeating: "  ", count: $0.depth) + $0.leafName }
        let width = labels.map(\.displayWidth).max() ?? 0
        let countWidth = rows.map { String($0.count).count }.max() ?? 1
        var out = ""
        for (row, label) in zip(rows, labels) {
            var line = label.padded(toWidth: width) + "  " + String(row.count).leftPadded(toWidth: countWidth)
            if row.total != row.count { line += "  (\(row.total) with subfolders)" }
            out += line + "\n"
        }
        return out
    }

    static func namedCounts(_ items: [NamedCount], empty: String) -> String {
        guard !items.isEmpty else { return empty + "\n" }
        let width = items.map { String($0.count).count }.max() ?? 1
        return items.map { String($0.count).leftPadded(toWidth: width) + "  " + $0.name }.joined(separator: "\n") + "\n"
    }

    // MARK: info

    static func info(_ library: AgentLibrary, stats: LibraryStats, settingsExists: Bool, executable: String) -> String {
        var lines: [(String, String)] = []
        lines.append(("Library", "\(library.root.path) (\(library.location.source.displayName))"))
        if !library.rootExists && library.loadError == nil {     // denied access isn't "missing"
            lines.append(("", "the folder doesn't exist yet; Kan creates it when it saves the first call"))
        }
        if let error = library.loadError { lines.append(("", "can't be read: \(error)")) }
        var calls = "\(stats.calls)"
        let statuses = stats.byStatus.sorted { a, b in a.value != b.value ? a.value > b.value : a.key.rawValue < b.key.rawValue }
        if !statuses.isEmpty { calls += " (" + statuses.map { "\($0.value) \($0.key.rawValue)" }.joined(separator: ", ") + ")" }
        calls += " · \(stats.starred) starred · \(stats.unlabeled) not labeled"
        lines.append(("Calls", calls))
        if let first = stats.first, let last = stats.last {
            lines.append(("Span", "\(AgentFormat.shortDate(first.startedAt, timeZone: first.timeZone)) → "
                          + "\(AgentFormat.shortDate(last.startedAt, timeZone: last.timeZone)) · "
                          + "\(KanTime.humanDuration(stats.totalSeconds)) recorded"))
        }
        lines.append(("Folders", "\(stats.folders) · tags \(stats.tags) · people \(stats.people)"))
        let s = library.settings
        lines.append(("Settings", library.settingsFile.path + (settingsExists ? "" : " (not created yet: defaults)")))
        if let problem = library.settingsProblem { lines.append(("", problem)) }
        lines.append(("", "you: \(s.effectiveUserName) · language: \(s.languageMode.displayName) · diarization: \(s.diarize ? "on" : "off")"))
        let retention = s.audioRetentionDays.map { "\($0) days" } ?? "forever"
        lines.append(("", "keep audio: \(s.keepAudio ? "yes, \(retention)" : "no") · remember voices: \(s.rememberVoices ? "yes" : "no") · auto-detect calls: \(s.autoDetect ? "yes" : "no")"))
        lines.append(("", "models: general \(s.generalModelID), English \(s.englishModelID), Bangla \(s.banglaModelID)"))
        lines.append(("", "OpenAI: title ideas \(s.aiSuggestTitles ? "on" : "off") · summaries \(s.aiSummarize ? "on" : "off")"
                      + " · model \(s.effectiveAIModel)"))
        lines.append(("Agents", "`kan mcp-config` prints MCP setup; \(library.store.agentsGuideURL.lastPathComponent) in the library explains the files"))
        lines.append(("kan", "\(KanVersion.current) · \(executable)"))
        let width = lines.map(\.0.count).max() ?? 0
        return lines.map { ($0.0.padded(toWidth: width) + "  " + $0.1).trimmingTrailingSpaces }.joined(separator: "\n") + "\n"
    }

    static func settingsJSON(_ s: KanSettings) -> JSONValue {
        var o: [String: JSONValue] = [
            "user_name": .string(s.effectiveUserName),
            "library_path": .string(s.libraryPath),
            "language_mode": .string(s.languageMode.rawValue),
            "general_model": .string(s.generalModelID),
            "english_model": .string(s.englishModelID),
            "bangla_model": .string(s.banglaModelID),
            "diarize": .bool(s.diarize),
            "keep_audio": .bool(s.keepAudio),
            "remember_voices": .bool(s.rememberVoices),
            "auto_detect": .bool(s.autoDetect),
            "ai_suggest_titles": .bool(s.aiSuggestTitles),
            "ai_summarize": .bool(s.aiSummarize),
            "ai_model": .string(s.effectiveAIModel),
            "ai_language": .string(s.aiLanguage.rawValue),
        ]
        if let days = s.audioRetentionDays { o["audio_retention_days"] = .int(days) }
        return .object(o)
    }
}

extension String {
    var trimmingTrailingSpaces: String {
        var s = Substring(self)
        while s.last == " " { s = s.dropLast() }
        return String(s)
    }
}
